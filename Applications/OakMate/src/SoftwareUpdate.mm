#import "SoftwareUpdate.h"
#import <OakFoundation/OakCompareVersionStrings.h>
#import <Security/Security.h>

NSString* const kUserDefaultsDisableSoftwareUpdateKey        = @"disableSoftwareUpdate";
NSString* const kUserDefaultsSkippedSoftwareUpdateVersionKey = @"skippedSoftwareUpdateVersion";

static NSString* const kLatestReleaseURL     = @"https://api.github.com/repos/OakMate/OakMate/releases/latest";
static NSTimeInterval const kCheckInterval   = 24*60*60;

@interface SoftwareUpdateRelease : NSObject
@property (nonatomic) NSString* version;     // E.g. ‘2.1.0’
@property (nonatomic) NSString* notes;       // Markdown
@property (nonatomic) NSURL*    pageURL;     // Release on github.com
@property (nonatomic) NSURL*    archiveURL;  // OakMate-«version».zip
@end

@implementation SoftwareUpdateRelease
@end

@interface SoftwareUpdate ()
{
	NSBackgroundActivityScheduler* _scheduler;
}
@property (nonatomic, getter = isBusy) BOOL busy;
@property (nonatomic) NSPanel* progressPanel;
@property (nonatomic) NSURLSessionDownloadTask* downloadTask;
@end

static NSString* CurrentVersion ()
{
	return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

// Returns the designated requirement of the running application if it is signed by a team (Developer ID), otherwise NULL
static SecRequirementRef CopyTeamSignedRequirement ()
{
	SecRequirementRef res = NULL;

	SecCodeRef code;
	if(SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess)
	{
		SecStaticCodeRef staticCode;
		if(SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &staticCode) == errSecSuccess)
		{
			CFDictionaryRef info;
			if(SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info) == errSecSuccess)
			{
				if(CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier))
					SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &res);
				CFRelease(info);
			}
			CFRelease(staticCode);
		}
		CFRelease(code);
	}
	return res;
}

static NSError* UpdateError (NSString* description)
{
	return [NSError errorWithDomain:@"com.isztld.oakmate.SoftwareUpdate" code:1 userInfo:@{ NSLocalizedDescriptionKey: description }];
}

@implementation SoftwareUpdate
+ (instancetype)sharedInstance
{
	static SoftwareUpdate* sharedInstance = [self new];
	return sharedInstance;
}

- (void)scheduleAutomaticChecks
{
	if([NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsDisableSoftwareUpdateKey])
		return;

	_scheduler = [[NSBackgroundActivityScheduler alloc] initWithIdentifier:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".SoftwareUpdate"]];
	_scheduler.interval  = kCheckInterval;
	_scheduler.tolerance = kCheckInterval / 4;
	_scheduler.repeats   = YES;
	_scheduler.qualityOfService = NSQualityOfServiceUtility;
	[_scheduler scheduleWithBlock:^(NSBackgroundActivityCompletionHandler completionHandler){
		dispatch_async(dispatch_get_main_queue(), ^{
			if(![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsDisableSoftwareUpdateKey])
				[self checkInBackground:YES];
			completionHandler(NSBackgroundActivityResultFinished);
		});
	}];
}

- (IBAction)checkForUpdates:(id)sender
{
	[self checkInBackground:NO];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
	return !self.isBusy;
}

// ==================
// = Find a Release =
// ==================

- (void)checkInBackground:(BOOL)backgroundFlag
{
	if(self.isBusy)
		return;
	self.busy = YES;

	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kLatestReleaseURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
	[request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
	[request setValue:[NSString stringWithFormat:@"OakMate/%@", CurrentVersion()] forHTTPHeaderField:@"User-Agent"];

	[[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error){
		SoftwareUpdateRelease* release = nil;
		if(!error)
		{
			NSInteger status = [(NSHTTPURLResponse*)response statusCode];
			if(status == 200)
					release = [self releaseFromJSON:data error:&error];
			else if(status == 404)
					error = UpdateError(@"No release of OakMate has been published yet.");
			else if((status == 403 || status == 429) && [[(NSHTTPURLResponse*)response valueForHTTPHeaderField:@"X-RateLimit-Remaining"] isEqualToString:@"0"])
			{
				NSDate* resetDate = [NSDate dateWithTimeIntervalSince1970:[[(NSHTTPURLResponse*)response valueForHTTPHeaderField:@"X-RateLimit-Reset"] doubleValue]];
				NSString* resetTime = [NSDateFormatter localizedStringFromDate:resetDate dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
				error = UpdateError([NSString stringWithFormat:@"GitHub limits how often it can be asked for updates from your network. Please try again after %@.", resetTime]);
			}
			else	error = UpdateError([NSString stringWithFormat:@"GitHub responded with status %ld.", status]);
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			self.busy = NO;
			[self didFindRelease:release error:error inBackground:backgroundFlag];
		});
	}] resume];
}

- (SoftwareUpdateRelease*)releaseFromJSON:(NSData*)data error:(NSError**)error
{
	NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
	if(![json isKindOfClass:[NSDictionary class]] || ![json[@"tag_name"] isKindOfClass:[NSString class]])
	{
		*error = UpdateError(@"Unexpected response from GitHub.");
		return nil;
	}

	SoftwareUpdateRelease* res = [[SoftwareUpdateRelease alloc] init];
	res.version = [json[@"tag_name"] hasPrefix:@"v"] ? [json[@"tag_name"] substringFromIndex:1] : json[@"tag_name"];
	res.notes   = [json[@"body"] isKindOfClass:[NSString class]] ? json[@"body"] : @"";
	res.pageURL = [NSURL URLWithString:json[@"html_url"]];

	NSString* archiveName = [NSString stringWithFormat:@"OakMate-%@.zip", res.version];
	for(NSDictionary* asset in json[@"assets"])
	{
		if([asset[@"name"] isEqual:archiveName])
			res.archiveURL = [NSURL URLWithString:asset[@"browser_download_url"]];
	}
	return res;
}

- (void)didFindRelease:(SoftwareUpdateRelease*)release error:(NSError*)error inBackground:(BOOL)backgroundFlag
{
	if(error)
	{
		os_log_error(OS_LOG_DEFAULT, "Software update check failed: %{public}@", error.localizedDescription);
		if(!backgroundFlag)
		{
			NSAlert* alert = [[NSAlert alloc] init];
			alert.messageText     = @"Unable to Check for Updates";
			alert.informativeText = error.localizedDescription;
			[alert runModal];
		}
		return;
	}

	BOOL isNewer = OakCompareVersionStrings(release.version, CurrentVersion()) == NSOrderedDescending;
	if(!isNewer || (backgroundFlag && [release.version isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsSkippedSoftwareUpdateVersionKey]]))
	{
		if(!backgroundFlag)
		{
			NSAlert* alert = [[NSAlert alloc] init];
			alert.messageText     = @"OakMate Is Up to Date";
			alert.informativeText = [NSString stringWithFormat:@"Version %@ is the newest version available.", CurrentVersion()];
			[alert runModal];
		}
		return;
	}

	NSTextView* notesView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 200)];
	notesView.editable = NO;
	notesView.textContainerInset = NSMakeSize(4, 4);
	notesView.string = release.notes;

	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 200)];
	scrollView.documentView        = notesView;
	scrollView.hasVerticalScroller = YES;
	scrollView.borderType          = NSBezelBorder;

	BOOL canInstall = release.archiveURL != nil;

	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText     = [NSString stringWithFormat:@"OakMate %@ Is Available", release.version];
	alert.informativeText = [NSString stringWithFormat:@"You have version %@.", CurrentVersion()];
	alert.accessoryView   = scrollView;
	[alert addButtonWithTitle:canInstall ? @"Install and Relaunch" : @"View Release"];
	[alert addButtonWithTitle:@"Later"];
	[alert addButtonWithTitle:@"Skip This Version"];

	NSModalResponse choice = [alert runModal];
	if(choice == NSAlertFirstButtonReturn)
	{
		if(canInstall)
				[self installRelease:release];
		else	[NSWorkspace.sharedWorkspace openURL:release.pageURL];
	}
	else if(choice == NSAlertThirdButtonReturn)
	{
		[NSUserDefaults.standardUserDefaults setObject:release.version forKey:kUserDefaultsSkippedSoftwareUpdateVersionKey];
	}
}

// ===========
// = Install =
// ===========

- (void)installRelease:(SoftwareUpdateRelease*)release
{
	SecRequirementRef requirement = CopyTeamSignedRequirement();
	if(!requirement)
	{
		// We can’t verify the download, so leave installing it to the user
		[NSWorkspace.sharedWorkspace openURL:release.pageURL];
		return;
	}

	self.busy = YES;
	[self showProgressForVersion:release.version];

	self.downloadTask = [NSURLSession.sharedSession downloadTaskWithURL:release.archiveURL completionHandler:^(NSURL* location, NSURLResponse* response, NSError* error){
		NSURL* appURL = nil;
		if(!error && [(NSHTTPURLResponse*)response statusCode] != 200)
			error = UpdateError([NSString stringWithFormat:@"Downloading the update failed with status %ld.", [(NSHTTPURLResponse*)response statusCode]]);
		if(!error)
			appURL = [self verifiedApplicationFromArchive:location version:release.version requirement:requirement error:&error];
		CFRelease(requirement);

		dispatch_async(dispatch_get_main_queue(), ^{
			[self.progressPanel orderOut:self];
			self.progressPanel = nil;
			self.downloadTask  = nil;
			self.busy          = NO;

			NSError* installError = error;
			if(appURL && [self replaceApplicationWith:appURL error:&installError])
			{
				[self relaunch];
			}
			else if(installError.code != NSURLErrorCancelled)
			{
				NSAlert* alert = [[NSAlert alloc] init];
				alert.messageText     = @"Unable to Install Update";
				alert.informativeText = [NSString stringWithFormat:@"%@\n\nYou can download OakMate %@ from GitHub instead.", installError.localizedDescription, release.version];
				[alert addButtonWithTitle:@"Open Release Page"];
				[alert addButtonWithTitle:@"Cancel"];
				if([alert runModal] == NSAlertFirstButtonReturn)
					[NSWorkspace.sharedWorkspace openURL:release.pageURL];
			}
		});
	}];
	[self.downloadTask resume];
}

// Extract the archive next to the installed application (same volume, so it can be swapped in) and verify its signature
- (NSURL*)verifiedApplicationFromArchive:(NSURL*)archiveURL version:(NSString*)version requirement:(SecRequirementRef)requirement error:(NSError**)error
{
	NSFileManager* fm = NSFileManager.defaultManager;
	NSURL* stagingURL = [fm URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:NSBundle.mainBundle.bundleURL create:YES error:error];
	if(!stagingURL)
		return nil;

	NSTask* ditto = [[NSTask alloc] init];
	ditto.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
	ditto.arguments     = @[ @"-x", @"-k", archiveURL.path, stagingURL.path ];
	if(![ditto launchAndReturnError:error])
		return nil;
	[ditto waitUntilExit];
	if(ditto.terminationStatus != 0)
		return *error = UpdateError(@"The downloaded archive could not be extracted."), nil;

	NSURL* appURL = [stagingURL URLByAppendingPathComponent:@"OakMate.app" isDirectory:YES];
	NSBundle* bundle = [NSBundle bundleWithURL:appURL];
	if(![bundle.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier] || ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:version])
		return *error = UpdateError(@"The downloaded archive does not contain the expected version of OakMate."), nil;

	SecStaticCodeRef staticCode;
	OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)appURL, kSecCSDefaultFlags, &staticCode);
	if(status == errSecSuccess)
	{
		status = SecStaticCodeCheckValidity(staticCode, kSecCSCheckAllArchitectures|kSecCSCheckNestedCode|kSecCSStrictValidate, requirement);
		CFRelease(staticCode);
	}

	if(status != errSecSuccess)
	{
		NSString* message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
		return *error = UpdateError([NSString stringWithFormat:@"The code signature of the downloaded update is not valid: %@", message]), nil;
	}
	return appURL;
}

- (BOOL)replaceApplicationWith:(NSURL*)newAppURL error:(NSError**)error
{
	NSURL* appURL = NSBundle.mainBundle.bundleURL;
	NSURL* resultingURL;
	if(![NSFileManager.defaultManager replaceItemAtURL:appURL withItemAtURL:newAppURL backupItemName:nil options:0 resultingItemURL:&resultingURL error:error])
		return NO;
	os_log(OS_LOG_DEFAULT, "Installed update at %{public}@", resultingURL.path);
	[NSFileManager.defaultManager removeItemAtURL:newAppURL.URLByDeletingLastPathComponent error:nil];
	return YES;
}

- (void)relaunch
{
	// Wait for this process to exit, then open the (new) application
	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
	task.arguments     = @[ @"-c", @"while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"", @"sh", [NSString stringWithFormat:@"%d", getpid()], NSBundle.mainBundle.bundlePath ];
	NSError* error;
	if([task launchAndReturnError:&error])
			[NSApp terminate:self];
	else	os_log_error(OS_LOG_DEFAULT, "Failed to relaunch: %{public}@", error.localizedDescription);
}

// ============
// = Progress =
// ============

- (void)showProgressForVersion:(NSString*)version
{
	NSTextField* label = [NSTextField labelWithString:[NSString stringWithFormat:@"Downloading OakMate %@…", version]];
	NSProgressIndicator* progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
	progress.indeterminate = YES;
	[progress startAnimation:self];
	NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelDownload:)];

	NSStackView* stack = [NSStackView stackViewWithViews:@[ label, progress, cancel ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment   = NSLayoutAttributeTrailing;
	stack.edgeInsets  = NSEdgeInsetsMake(20, 20, 20, 20);
	[label.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:20].active = YES;
	[progress.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:20].active = YES;
	[progress.widthAnchor constraintEqualToConstant:300].active = YES;

	self.progressPanel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	self.progressPanel.title       = @"Software Update";
	self.progressPanel.contentView = stack;
	self.progressPanel.releasedWhenClosed = NO;
	[self.progressPanel center];
	[self.progressPanel makeKeyAndOrderFront:self];
}

- (void)cancelDownload:(id)sender
{
	[self.downloadTask cancel];
}
@end
