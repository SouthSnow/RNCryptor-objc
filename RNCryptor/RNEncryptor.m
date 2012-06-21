//
//  RNEncryptor
//
//  Copyright (c) 2012 Rob Napier
//
//  This code is licensed under the MIT License:
//
//  Permission is hereby granted, free of charge, to any person obtaining a 
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//


#import "RNCryptor+Private.h"
#import "RNEncryptor.h"
#import "RNCryptorEngine.h"

@interface RNEncryptor ()
@property (nonatomic, readonly) NSUInteger HMACLength;
@property (nonatomic, readwrite, copy) RNCryptorHandler handler;
@property (nonatomic, readwrite, copy) RNCryptorCompletion completion;
@end

@implementation RNEncryptor
{
  CCHmacContext _HMACContext;
}
@synthesize handler = _handler;
@synthesize completion = _completion;
@synthesize HMACLength = __HMACLength;

+ (NSData *)encryptData:(NSData *)thePlaintext withSettings:(RNCryptorSettings)theSettings password:(NSString *)aPassword error:(NSError **)anError
{
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  __block NSData *encryptedData;
  __block NSError *returnedError;
  RNEncryptor *cryptor = [[self alloc] initWithSettings:theSettings
                                               password:aPassword
                                                handler:nil completion:^(NSData *d, NSError *e) {
        encryptedData = d;
        returnedError = e;
        dispatch_semaphore_signal(sem);
      }];
  dispatch_queue_t queue = dispatch_queue_create("net.robnapier.RNEncryptor.response", DISPATCH_QUEUE_SERIAL);
  cryptor.responseQueue = queue;
  [cryptor addData:thePlaintext];
  [cryptor finish];

  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

  if (anError) {
    *anError = returnedError;
  }

  dispatch_release(sem);
  dispatch_release(queue);

  return encryptedData;
}

- (RNEncryptor *)initWithSettings:(RNCryptorSettings)theSettings encryptionKey:(NSData *)anEncryptionKey HMACKey:(NSData *)anHMACKey handler:(RNCryptorHandler)aHandler completion:(RNCryptorCompletion)aCompletion
{
  self = [super init];
  if (self) {
    NSData *IV = [[self class] randomDataOfLength:theSettings.IVSize];
    [self.outData setData:IV];

    if (anHMACKey) {
      CCHmacInit(&_HMACContext, theSettings.HMACAlgorithm, anHMACKey.bytes, anHMACKey.length);
      __HMACLength = theSettings.HMACLength;
    }

    _handler = [aHandler copy];
    _completion = [aCompletion copy];

    NSError *error;
    self.engine = [[RNCryptorEngine alloc] initWithOperation:kCCEncrypt
                                                    settings:theSettings
                                                         key:anEncryptionKey
                                                          IV:IV
                                                       error:&error];
    if (!self.engine) {
      [self cleanupAndNotifyWithError:error];
      self = nil;
      return nil;
    }
  }

  return self;
}

- (RNEncryptor *)initWithSettings:(RNCryptorSettings)theSettings password:(NSString *)aPassword handler:(RNCryptorHandler)aHandler completion:(RNCryptorCompletion)aCompletion
{
  NSParameterAssert(aPassword != nil);

  NSData *encryptionKeySalt = [[self class] randomDataOfLength:theSettings.keySettings.saltSize];
  NSData *encryptionKey = [[self class] keyForPassword:aPassword withSalt:encryptionKeySalt andSettings:theSettings.keySettings];

  NSData *HMACKeySalt = [[self class] randomDataOfLength:theSettings.HMACKeySettings.saltSize];
  NSData *HMACKey = [[self class] keyForPassword:aPassword withSalt:HMACKeySalt andSettings:theSettings.HMACKeySettings];

  uint8_t header[2] = {0, 0};
  NSMutableData *headerData = [NSMutableData dataWithBytes:header length:sizeof(header)];
  [headerData appendData:encryptionKeySalt];
  [headerData appendData:HMACKeySalt];

  self = [self initWithSettings:theSettings
                  encryptionKey:encryptionKey
                        HMACKey:HMACKey
                        handler:aHandler
                     completion:aCompletion];
  if (self) {
    // Prepend our header
    [headerData appendData:self.outData];
    [self.outData setData:headerData];
  }
  return self;
}

- (void)cleanup
{
  _handler = nil;
  _completion = nil;
  [super cleanup];
}

- (void)addData:(NSData *)data
{
  NSAssert(self.engine != NULL, @"Cryptor has be completed");

  dispatch_async(self.queue, ^{
    NSError *error;
    NSData *encryptedData = [self.engine addData:data error:&error];
    if (!encryptedData) {
      [self cleanupAndNotifyWithError:error];
    }
    CCHmacUpdate(&_HMACContext, encryptedData.bytes, encryptedData.length);

    [self.outData appendData:encryptedData];

    if (self.handler) {
      dispatch_sync(self.responseQueue, ^{
        self.handler(self.outData);
      });
      [self.outData setLength:0];
    }
  });
}

- (void)finish
{
  NSAssert(self.engine != NULL, @"Cryptor has be completed");

  dispatch_async(self.queue, ^{
    NSError *error;
    NSData *encryptedData = [self.engine finishWithError:&error];
    [self.outData appendData:encryptedData];
    CCHmacUpdate(&_HMACContext, encryptedData.bytes, encryptedData.length);
    NSMutableData *HMACData = [NSMutableData dataWithLength:self.HMACLength];
    CCHmacFinal(&_HMACContext, [HMACData mutableBytes]);

    [self.outData appendData:HMACData];

    [self cleanupAndNotifyWithError:error];
  });
}

- (void)cleanupAndNotifyWithError:(NSError *)error
{
  if (self.completion) {
    dispatch_sync(self.responseQueue, ^{
      self.completion(self.outData, error);
    });
  }
  [self cleanup];
}

@end