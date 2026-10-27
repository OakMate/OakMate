// Checks GitHub for a newer release of OakMate and installs it.
//
// Releases are published by .github/workflows/release.yml. An update is only
// installed when its code signature satisfies the designated requirement of
// the running application (same bundle identifier and signing team). Builds
// without a team identifier (e.g. local builds) open the release page instead.

extern NSString* const kUserDefaultsDisableSoftwareUpdateKey;
extern NSString* const kUserDefaultsSkippedSoftwareUpdateVersionKey;

@interface SoftwareUpdate : NSObject
@property (class, readonly) SoftwareUpdate* sharedInstance;
- (void)scheduleAutomaticChecks;
- (IBAction)checkForUpdates:(id)sender;
@end
