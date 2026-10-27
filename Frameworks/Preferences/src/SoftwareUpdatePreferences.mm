#import "SoftwareUpdatePreferences.h"
#import "Keys.h"
#import <OakAppKit/NSImage Additions.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/OakStringListTransformer.h>
#import <SoftwareUpdate/SoftwareUpdate.h>
#import <MenuBuilder/MenuBuilder.h>

@interface SoftwareUpdatePreferences ()
{
	id _relativeDateUserDefaultsObserver;
	NSTimer* _relativeDateUpdateTimer;
}
@property (nonatomic) NSString* relativeStringForLastCheck;
@end

@implementation SoftwareUpdatePreferences
+ (NSSet*)keyPathsForValuesAffectingLastCheckDescription { return [NSSet setWithObjects:@"softwareUpdateController.checking", @"softwareUpdateController.errorString", @"relativeStringForLastCheck", nil]; }

- (id)init
{
	if(self = [super initWithNibName:nil label:@"Software Update" image:[NSImage imageNamed:@"Software Update" inSameBundleAsClass:[self class]]])
	{
		[OakStringListTransformer createTransformerWithName:@"OakSoftwareUpdateChannelTransformer" andObjectsArray:@[ kSoftwareUpdateChannelRelease, kSoftwareUpdateChannelPrerelease ]];
	}
	return self;
}

- (SoftwareUpdate*)softwareUpdateController
{
	return SoftwareUpdate.sharedInstance;
}

- (NSString*)lastCheckDescription
{
	return self.softwareUpdateController.isChecking ? @"Checking…" : (self.softwareUpdateController.errorString ?: _relativeStringForLastCheck ?: @"Never");
}

- (NSString*)relativeStringForDate:(NSDate*)date
{
	if(!date)
		return nil;

	return -[date timeIntervalSinceNow] < 5 ? @"Just now" : [[[NSRelativeDateTimeFormatter alloc] init] localizedStringForDate:date relativeToDate:NSDate.now];
}

- (void)viewWillAppear
{
	_relativeDateUserDefaultsObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* notification){
		self.relativeStringForLastCheck = [self relativeStringForDate:[NSUserDefaults.standardUserDefaults objectForKey:kUserDefaultsLastSoftwareUpdateCheckKey]];
	}];

	_relativeDateUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer* timer){
		self.relativeStringForLastCheck = [self relativeStringForDate:[NSUserDefaults.standardUserDefaults objectForKey:kUserDefaultsLastSoftwareUpdateCheckKey]];
	}];

	self.relativeStringForLastCheck = [self relativeStringForDate:[NSUserDefaults.standardUserDefaults objectForKey:kUserDefaultsLastSoftwareUpdateCheckKey]];
}

- (void)viewDidDisappear
{
	[_relativeDateUpdateTimer invalidate];
	[NSNotificationCenter.defaultCenter removeObserver:_relativeDateUserDefaultsObserver];
}

- (void)loadView
{
	NSButton* watchForUpdatesCheckBox      = OakCreateCheckBox(@"Watch for:");
	NSPopUpButton* updateChannelPopUp      = OakCreatePopUpButton();
	NSButton* askBeforeDownloadingCheckBox = OakCreateCheckBox(@"Ask before downloading updates");

	NSStackView* watchForStackView = [NSStackView stackViewWithViews:@[ watchForUpdatesCheckBox, updateChannelPopUp ]];
	watchForStackView.alignment = NSLayoutAttributeFirstBaseline;

	NSTextField* lastCheckTextField        = OakCreateLabel(@"Some time ago");
	NSButton* checkNowButton               = [NSButton buttonWithTitle:@"Check Now" target:self.softwareUpdateController action:@selector(checkForUpdate:)];

	NSButton* submitCrashReportsCheckBox   = OakCreateCheckBox(@"Submit to MacroMates");

	NSTextField* contactTextField          = [NSTextField textFieldWithString:@"Anonymous"];

	NSFont* smallFont = [NSFont messageFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	contactTextField.font        = smallFont;
	contactTextField.controlSize = NSControlSizeSmall;

	NSStackView* contactStackView = [NSStackView stackViewWithViews:@[
		OakCreateLabel(@"Contact:", smallFont), contactTextField
	]];
	contactStackView.alignment  = NSLayoutAttributeFirstBaseline;
	contactStackView.edgeInsets = { .left = 18 };
	[contactStackView setHuggingPriority:NSLayoutPriorityDefaultHigh-1 forOrientation:NSLayoutConstraintOrientationVertical];

	MBMenu const updateChannelMenuItems = {
		{ @"Normal releases", .tag = 0 },
		{ @"Prereleases",     .tag = 1 },
	};
	MBCreateMenu(updateChannelMenuItems, updateChannelPopUp.menu);

	NSGridView* gridView = [NSGridView gridViewWithViews:@[
		@[ OakCreateLabel(@"Software update:"),        watchForStackView                 ],
		@[ NSGridCell.emptyContentView,                askBeforeDownloadingCheckBox      ],
		@[ ],
		@[ OakCreateLabel(@"Last check:"),             lastCheckTextField                ],
		@[ NSGridCell.emptyContentView,                checkNowButton                    ],
		@[ ],
		@[ OakCreateLabel(@"Crash reports:"),          submitCrashReportsCheckBox        ],
		@[ NSGridCell.emptyContentView,                contactStackView                  ],
	]];

	[contactTextField.trailingAnchor constraintEqualToAnchor:updateChannelPopUp.trailingAnchor].active = YES;

	self.view = OakSetupGridViewWithSeparators(gridView, { 2, 5 });

	[watchForUpdatesCheckBox      bind:NSValueBinding       toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsDisableSoftwareUpdateKey]   options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
	[updateChannelPopUp           bind:NSSelectedTagBinding toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsSoftwareUpdateChannelKey]   options:@{ NSValueTransformerNameBindingOption: @"OakSoftwareUpdateChannelTransformer" }];
	[askBeforeDownloadingCheckBox bind:NSValueBinding       toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsAskBeforeUpdatingKey]       options:nil];
	[lastCheckTextField           bind:NSValueBinding       toObject:self                                                  withKeyPath:@"lastCheckDescription"                                                           options:nil];
	[submitCrashReportsCheckBox   bind:NSValueBinding       toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsDisableCrashReportingKey]   options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
	[contactTextField             bind:NSValueBinding       toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsCrashReportsContactInfoKey] options:nil];

	[updateChannelPopUp           bind:NSEnabledBinding     toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsDisableSoftwareUpdateKey]   options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
	[askBeforeDownloadingCheckBox bind:NSEnabledBinding     toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsDisableSoftwareUpdateKey]   options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
	[checkNowButton               bind:NSEnabledBinding     toObject:self.softwareUpdateController                         withKeyPath:@"checking"                                                                       options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
	[contactTextField             bind:NSEnabledBinding     toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[NSString stringWithFormat:@"values.%@", kUserDefaultsDisableCrashReportingKey]   options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
}
@end
