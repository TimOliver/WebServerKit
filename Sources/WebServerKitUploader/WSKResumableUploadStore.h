#import <Foundation/Foundation.h>

#import "WSKFileRequest.h"
#import "WSKResponse.h"

NS_ASSUME_NONNULL_BEGIN

// Private uploader implementation. A completed PATCH body is disposable until the
// store commits it; aborting a body never advances the durable session offset.
@interface WSKResumableFileRequest : WSKFileRequest
@end

typedef WSKResponse *_Nullable (^WSKResumableUploadValidationBlock)(NSDictionary<NSString *, NSString *> *metadata);

// Persist this record BEFORE the atomic rename. Recovery only recognizes or
// removes a file whose device and inode still match the recorded staging file.
typedef BOOL (^WSKResumableUploadJournalBlock)(NSString *finalPath, NSString *stagingPath, unsigned long long device, unsigned long long inode, NSError *_Nullable *_Nullable error);
typedef WSKResponse *_Nullable (^WSKResumableUploadPublicationBlock)(NSString *temporaryPath, NSDictionary<NSString *, NSString *> *metadata, WSKResumableUploadJournalBlock journal);

@interface WSKResumableUploadStore : NSObject
- (instancetype)initWithDirectory:(NSString *)directory uploadDirectory:(NSString *)uploadDirectory expirationInterval:(NSTimeInterval)expirationInterval;
- (WSKResponse *)processRequest:(WSKRequest *)request validate:(WSKResumableUploadValidationBlock)validate publish:(WSKResumableUploadPublicationBlock)publish;
- (void)cleanupExpiredUploads;
@end

NS_ASSUME_NONNULL_END
