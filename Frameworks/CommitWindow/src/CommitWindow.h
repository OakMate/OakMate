// CommitWindowTool sends a property list with its arguments and environment
// over a Unix domain socket and receives a property list with the output and
// return code when the commit window is closed.

static NSString* const kOakCommitWindowArguments            = @"arguments";
static NSString* const kOakCommitWindowEnvironment          = @"environment";
static NSString* const kOakCommitWindowStandardOutput       = @"stdout";
static NSString* const kOakCommitWindowStandardError        = @"stderr";
static NSString* const kOakCommitWindowReturnCode           = @"returnCode";
static NSString* const kOakCommitWindowContinue             = @"continue";

#ifdef __cplusplus
// Socket name for the OakMate process with the given bundle identifier and pid
inline std::string OakCommitWindowSocketName (std::string const& bundleIdentifier, std::string const& pid)
{
	return bundleIdentifier + "." + pid + ".commit-window";
}
#endif

@interface OakCommitWindowServer : NSObject
@property (class, readonly) OakCommitWindowServer* sharedInstance;
@end
