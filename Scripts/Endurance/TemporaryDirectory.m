// Loaded only into the endurance host. Foundation on macOS ignores TMPDIR in
// favor of the user's system temp folder. Redirect its API so abandoned upload
// files can be detected without scanning or touching another process's files.
// This must be a separate image: dyld does not interpose calls from the image
// containing the replacement itself. Nothing in the shipping library changes.
#import <Foundation/Foundation.h>

static NSString *EnduranceTemporaryDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ directory = @(getenv("TMPDIR")); });
    return directory;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} temporaryDirectoryOverride = {(const void *)&EnduranceTemporaryDirectory, (const void *)&NSTemporaryDirectory};
