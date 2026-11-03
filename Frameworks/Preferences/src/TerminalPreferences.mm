#import "TerminalPreferences.h"
#import "Keys.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/NSImage Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <OakFoundation/OakStringListTransformer.h>
#import <OakFoundation/OakCompareVersionStrings.h>
#import <OakFoundation/OakFoundation.h>
#import <io/path.h>
#import <io/exec.h>
#import <ns/ns.h>
#import <regexp/format_string.h>
#import <bundles/bundles.h>
#import <authorization/helper.h>
#import <text/format.h>

static void CreateHyperLink (NSTextField* textField, NSString* text, NSString* url)
{
	[textField setAllowsEditingTextAttributes:YES];
	[textField setSelectable:YES];

	NSAttributedString* str = [textField attributedStringValue];
	NSRange range = [[str string] rangeOfString:text];

	NSMutableAttributedString* attrString = [str mutableCopy];
	[attrString beginEditing];
	[attrString addAttribute:NSLinkAttributeName value:url range:range];
	[attrString addAttribute:NSForegroundColorAttributeName value:[NSColor blueColor] range:range];
	[attrString addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
	[attrString endEditing];

	[textField setAttributedStringValue:attrString];
}

static bool is_permission_error (int error)
{
	return error == EACCES || error == EPERM;
}

static bool cp_requires_admin (std::string const& dst)
{
	return access(dst.c_str(), W_OK) != 0 && (access(dst.c_str(), X_OK) == 0 || access(path::parent(dst).c_str(), W_OK) != 0);
}

static bool install_mate (std::string const& src, std::string const& dst)
{
	struct stat buf;
	if(path::make_dir(path::parent(dst)) && (lstat(dst.c_str(), &buf) != 0 || S_ISREG(buf.st_mode) || unlink(dst.c_str()) == 0) && copyfile(src.c_str(), dst.c_str(), NULL, COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC) == 0)
		return true;

	if(!is_permission_error(errno))
	{
		perrorf("TerminalPreferences: install “%s”", dst.c_str());
		return false;
	}

	osx::authorization_t auth;
	if(!privileged_helper::authorize(auth, text::format("OakMate needs administrator privileges to install “mate” in %s.", path::with_tilde(path::parent(dst)).c_str())))
		return false;

	std::string const error = privileged_helper::copy_file(src, dst, auth);
	if(error != NULL_STR)
		os_log_error(OS_LOG_DEFAULT, "%{public}s", error.c_str());
	return error == NULL_STR;
}

static bool uninstall_mate (std::string const& path)
{
	if(unlink(path.c_str()) == 0 || errno == ENOENT)
		return true;

	if(!is_permission_error(errno))
	{
		perrorf("TerminalPreferences: unlink “%s”", path.c_str());
		return false;
	}

	osx::authorization_t auth;
	if(!privileged_helper::authorize(auth, text::format("OakMate needs administrator privileges to remove “%s”.", path::with_tilde(path).c_str())))
		return false;

	std::string const error = privileged_helper::remove_file(path, auth);
	if(error != NULL_STR)
		os_log_error(OS_LOG_DEFAULT, "%{public}s", error.c_str());
	return error == NULL_STR;
}

@implementation TerminalPreferences
- (id)init
{
	if(self = [super initWithNibName:@"TerminalPreferences" label:@"Terminal" image:[NSImage imageNamed:@"Terminal" inSameBundleAsClass:[self class]]])
	{
		[OakStringListTransformer createTransformerWithName:@"OakRMateInterfaceTransformer" andObjectsArray:@[ kRMateServerListenLocalhost, kRMateServerListenRemote ]];

		self.defaultsProperties = @{
			@"path":         kUserDefaultsMateInstallPathKey,
			@"disableRMate": kUserDefaultsDisableRMateServerKey,
			@"interface":    kUserDefaultsRMateServerListenKey,
			@"port":         kUserDefaultsRMateServerPortKey,
		};
	}
	return self;
}

- (void)selectInstallPath:(id)sender
{
	NSSavePanel* savePanel = [NSSavePanel savePanel];
	[savePanel setNameFieldStringValue:@"mate"];
	[savePanel beginSheetModalForWindow:[self view].window completionHandler:^(NSModalResponse result) {
		if(result == NSModalResponseOK)
				[self updatePopUp:[[savePanel.URL filePathURL] path]];
		else	[installPathPopUp selectItemAtIndex:0];
		[self updateUI:self];
	}];
}

- (void)updatePopUp:(NSString*)path
{
	NSMenu* menu = [installPathPopUp menu];
	[menu removeAllItems];

	// The first item is the default when mate is not installed
	NSArray<NSString*>* standardPaths = @[ @"~/.local/bin/mate", @"/usr/local/bin/mate", @"~/bin/mate" ];

	path = [path stringByAbbreviatingWithTildeInPath];
	if(path && ![standardPaths containsObject:path])
		[menu addItemWithTitle:path action:@selector(updateUI:) keyEquivalent:@""];
	for(NSString* standardPath in standardPaths)
		[menu addItemWithTitle:standardPath action:@selector(updateUI:) keyEquivalent:@""];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Other…" action:@selector(selectInstallPath:) keyEquivalent:@""];

	for(NSMenuItem* menuItem in menu.itemArray)
		menuItem.target = self;

	if(path)
		[installPathPopUp selectItemWithTitle:path];
}

- (void)updateUI:(id)sender
{
	BOOL isInstalled = self.mateInstallPath ? YES : NO;

	std::map<std::string, std::string> variables;
	if(isInstalled)
		variables["installed"] = "installed";
	variables["mate_path"] = to_s([self.mateInstallPath stringByAbbreviatingWithTildeInPath] ?: [installPathPopUp titleOfSelectedItem]);

	[installStatusText setStringValue:[NSString stringWithCxxString:format_string::expand(statusTextFormat, variables)]];
	[installSummaryText setStringValue:[NSString stringWithCxxString:format_string::expand(summaryTextFormat, variables)]];
	self.installIndicaitorImage = [NSImage imageNamed:(isInstalled ? NSImageNameStatusAvailable : NSImageNameStatusUnavailable)];

	[installPathPopUp setEnabled:isInstalled ? NO : YES];
	[installButton setAction:isInstalled ? @selector(performUninstallMate:) : @selector(performInstallMate:)];
	[installButton setState:isInstalled ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)loadView
{
	[super loadView];

	if(NSString* path = self.mateInstallPath)
	{
		if(access([path fileSystemRepresentation], F_OK) != 0)
		{
			[NSUserDefaults.standardUserDefaults removeObjectForKey:kUserDefaultsMateInstallPathKey];
			[NSUserDefaults.standardUserDefaults removeObjectForKey:kUserDefaultsMateInstallVersionKey];
		}
	}

	installPathPopUp.target = self;
	installButton.target = self;
	statusTextFormat  = to_s([installStatusText stringValue]);
	summaryTextFormat = to_s([installSummaryText stringValue]);
	[self updatePopUp:self.mateInstallPath];
	[self updateUI:self];

	CreateHyperLink(rmateSummaryText, @"rmate", @"https://github.com/textmate/rmate/");
	LSSetDefaultHandlerForURLScheme(CFSTR("txmt"), CFBundleGetIdentifier(CFBundleGetMainBundle()));
}

- (NSSize)preferredContentSize
{
	return self.view.frame.size;
}

- (NSString*)mateInstallPath
{
	NSString* path = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMateInstallPathKey];
	return [path stringByExpandingTildeInPath];
}

- (void)setMateInstallPath:(NSString*)aPath
{
	if(aPath)
			[NSUserDefaults.standardUserDefaults setObject:aPath forKey:kUserDefaultsMateInstallPathKey];
	else	[NSUserDefaults.standardUserDefaults removeObjectForKey:kUserDefaultsMateInstallPathKey];
}

- (void)installMateAs:(NSString*)dstPath
{
	if(NSString* srcPath = [NSBundle.mainBundle pathForAuxiliaryExecutable:@"mate"])
	{
		if(install_mate(to_s(srcPath), to_s(dstPath)))
		{
			[self setMateInstallPath:dstPath];
			std::string res = io::exec(to_s(srcPath), "--version", NULL);
			if(regexp::match_t const& m = regexp::search("\\Amate ([\\d.]+)", res))
				[NSUserDefaults.standardUserDefaults setObject:[NSString stringWithCxxString:m[1]] forKey:kUserDefaultsMateInstallVersionKey];
		}
	}
	else
	{
		NSAlert* alert        = [[NSAlert alloc] init];
		alert.messageText     = @"Unable to find ‘mate’";
		alert.informativeText = @"The ‘mate’ binary is missing from the application bundle. We recommend that you re-download the application.";
		[alert addButtonWithTitle:@"OK"];
		[alert runModal];
	}
	[self updateUI:self];
}

- (IBAction)performInstallMate:(id)sender
{
	NSString* dstObjPath = [[installPathPopUp titleOfSelectedItem] stringByExpandingTildeInPath];

	struct stat buf;
	std::string dstPath = to_s(dstObjPath);
	if(lstat(dstPath.c_str(), &buf) == 0)
	{
		char const* itemType = "An item";
		if(S_ISREG(buf.st_mode))
			itemType = "A file";
		else if(S_ISDIR(buf.st_mode))
			itemType = "A folder";
		else if(S_ISLNK(buf.st_mode))
			itemType = "A link";

		std::string summary = text::format("%s with the name “mate” already exists in the folder %s. Do you want to replace it?", itemType, path::with_tilde(path::parent(dstPath)).c_str());

		NSAlert* alert = [[NSAlert alloc] init];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:@"File Already Exists"];
		[alert setInformativeText:[NSString stringWithCxxString:summary]];
		[alert addButtons:@"Replace", @"Cancel", nil];
		[alert beginSheetModalForWindow:[self.view window] completionHandler:^(NSModalResponse returnCode){
			if(returnCode == NSAlertFirstButtonReturn)
				[self installMateAs:[[installPathPopUp titleOfSelectedItem] stringByExpandingTildeInPath]];
		}];
	}
	else
	{
		[self installMateAs:dstObjPath];
	}
	[self updateUI:self];
}

- (IBAction)performUninstallMate:(id)sender
{
	if(uninstall_mate(to_s(self.mateInstallPath)))
		[self setMateInstallPath:nil];
	[self updateUI:self];
}

+ (void)updateMateIfRequired
{
	NSString* oldMate    = [[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMateInstallPathKey] stringByExpandingTildeInPath];
	NSString* oldVersion = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMateInstallVersionKey];
	NSString* newMate    = [NSBundle.mainBundle pathForAuxiliaryExecutable:@"mate"];

	if(oldMate && newMate)
	{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
			std::string res = io::exec(to_s(newMate), "--version", NULL);
			if(regexp::match_t const& m = regexp::search("\\Amate ([\\d.]+)", res))
			{
				NSString* newVersion = [NSString stringWithCxxString:m[1]];
				if(OakCompareVersionStrings(oldVersion, newVersion) == NSOrderedAscending)
				{
					if(cp_requires_admin(to_s(oldMate)))
					{
						OakRunOnMainRunLoop(^{ // Not the main queue: the alert is modal
							NSAlert* alert        = [[NSAlert alloc] init];
							alert.messageText     = @"Update Shell Support";
							alert.informativeText = [NSString stringWithFormat:@"Would you like to update the installed version of mate to version %@?", newVersion];
							[alert addButtons:@"Update", @"Cancel", nil];
							if([alert runModal] == NSAlertFirstButtonReturn) // "Update"
							{
								if(!install_mate(to_s(newMate), to_s(oldMate)))
									return;
							}

							// Avoid asking again by storing the new version number
							[NSUserDefaults.standardUserDefaults setObject:newVersion forKey:kUserDefaultsMateInstallVersionKey];
						});
					}
					else
					{
						if(install_mate(to_s(newMate), to_s(oldMate)))
							[NSUserDefaults.standardUserDefaults setObject:newVersion forKey:kUserDefaultsMateInstallVersionKey];
					}
				}
			}
		});
	}
}
@end
