#import <oak/debug.h>
#import <OakSystem/application.h>
#import <DocumentWindow/DocumentWindowController.h>
#import <io/path.h>
#import <text/format.h>
#import <crash/info.h>

static void sig_int_handler (void* unused)
{
	os_log(OS_LOG_DEFAULT, "Received SIGINT: Regular shutdown.");
	[NSApp terminate:nil];
}

static void sig_term_handler (void* unused)
{
	os_log(OS_LOG_DEFAULT, "Received SIGTERM: Quick shutdown.");
	[DocumentWindowController saveSessionIncludingUntitledDocuments:YES];
	[NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillTerminateNotification object:NSApp];
	[NSApp stop:nil];
	[NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:NULL subtype:0 data1:0 data2:0] atStart:NO];
	[NSUserDefaults.standardUserDefaults synchronize];
}

static void increase_max_open_files (rlim_t required = 2048)
{
	struct rlimit limit;
	if(getrlimit(RLIMIT_NOFILE, &limit) == -1)
	{
		perror("getrlimit()");
		return;
	}

	if(limit.rlim_cur > required)
		return;

	rlim_t oldLimit = limit.rlim_cur;

	limit.rlim_cur = MIN(OPEN_MAX, limit.rlim_max);
	if(setrlimit(RLIMIT_NOFILE, &limit) == -1)
	{
		perror("setrlimit()");
		return;
	}

	if(getrlimit(RLIMIT_NOFILE, &limit) == 0)
		fprintf(stderr, "Increased maximum number of open files from %llu to %llu\n", oldLimit, limit.rlim_cur);
}

// On first launch, copy settings, bundles, and history from TextMate. The open
// documents of TextMate’s session are left alone since their backup files are
// managed by TextMate.
static void import_textmate_settings ()
{
	@autoreleasepool {
		NSFileManager* fm = NSFileManager.defaultManager;
		NSString* appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
		NSString* src = [appSupport stringByAppendingPathComponent:@"TextMate"];
		NSString* dst = [appSupport stringByAppendingPathComponent:@"OakMate"];

		if(![fm fileExistsAtPath:dst] && [fm fileExistsAtPath:src])
		{
			NSError* error;
			if([fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&error])
			{
				for(NSString* name in [fm contentsOfDirectoryAtPath:src error:nil])
				{
					if([name isEqualToString:@"Session"])
						continue;
					if(![fm copyItemAtPath:[src stringByAppendingPathComponent:name] toPath:[dst stringByAppendingPathComponent:name] error:&error])
						os_log_error(OS_LOG_DEFAULT, "Failed to copy ‘%{public}@’ from TextMate: %{public}@", name, error.localizedDescription);
				}
			}
			else
			{
				os_log_error(OS_LOG_DEFAULT, "Failed to create ‘%{public}@’: %{public}@", dst, error.localizedDescription);
			}
		}

		CFArrayRef ourKeys = CFPreferencesCopyKeyList(kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		BOOL firstLaunch = !ourKeys || CFArrayGetCount(ourKeys) == 0;
		if(ourKeys)
			CFRelease(ourKeys);

		if(firstLaunch)
		{
			if(CFDictionaryRef settings = CFPreferencesCopyMultiple(NULL, CFSTR("com.macromates.TextMate"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
			{
				CFPreferencesSetMultiple(settings, NULL, kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
				CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
				CFRelease(settings);
			}
		}
	}
}

int main (int argc, char const* argv[])
{
	import_textmate_settings();

	oak::application_t::set_support(path::join(path::home(), "Library/Application Support/OakMate"));
	oak::application_t app(argc, argv);

	increase_max_open_files();

	signal(SIGINT,  SIG_IGN);
	signal(SIGTERM, SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	dispatch_source_t sigTermSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler_f(sigTermSrc, &sig_term_handler);
	dispatch_resume(sigTermSrc);

	dispatch_source_t sigIntSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler_f(sigIntSrc, &sig_int_handler);
	dispatch_resume(sigIntSrc);

	@autoreleasepool {
		for(NSString* variable in [[[NSProcessInfo processInfo] environment] allKeys])
		{
			if([variable hasPrefix:@"TM_"])
				unsetenv([variable UTF8String]);
		}
	}

	try {
		return NSApplicationMain(argc, argv);
	}
	catch(std::exception const& e) {
		crash_reporter_info_t info("C++ Exception: %s", e.what());
		abort();
	}
}
