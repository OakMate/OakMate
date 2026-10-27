#import "BundlesManager.h"
#import <bundles/load.h>
#import "InstallBundleItems.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSString Additions.h>
#import "OakDownloadManager.h"
#import <bundles/locations.h>
#import <bundles/query.h> // set_index
#import <regexp/format_string.h>
#import <text/ctype.h>
#import <text/decode.h>
#import <ns/ns.h>
#import <io/path.h>
#import <io/move_path.h>
#import <io/entries.h>
#import <io/events.h>
#import <oak/debug.h>

NSString* const kUserDefaultsDisableBundleUpdatesKey       = @"disableBundleUpdates";
NSString* const kUserDefaultsLastBundleUpdateCheckKey      = @"lastBundleUpdateCheck";
NSString* const kUserDefaultsBundleUpdateFrequencyKey      = @"bundleUpdateFrequency";

static NSTimeInterval const kDefaultPollInterval = 3*60*60;
static char const* kBundleAttributeUpdated = "org.textmate.bundle.updated";

static NSString* SafeBasename (NSString* name)
{
	return [[name stringByReplacingOccurrencesOfString:@"/" withString:@":"] stringByReplacingOccurrencesOfString:@"." withString:@"_"];
}

@interface BundlesManager () <OakUserDefaultsObserver>
{
	NSBackgroundActivityScheduler* _updateBundleIndexScheduler;

	std::vector<std::string> bundlesPaths;
	std::string bundlesIndexPath;
	std::set<std::string> watchList;
	plist::cache_t cache;
}
@property (nonatomic) BOOL      autoUpdateBundles;

@property (nonatomic) BOOL      needsCreateBundlesIndex;
@property (nonatomic) BOOL      needsSaveBundlesIndex;

@property (nonatomic) NSArray<Bundle*>* bundles;

@property (nonatomic) NSString* installDirectory;
@property (nonatomic) NSString* localIndexPath;
@property (nonatomic) NSString* remoteIndexPath;
@property (nonatomic) NSURL*    remoteIndexURL;
@end

@implementation BundlesManager
+ (instancetype)sharedInstance
{
	static BundlesManager* sharedInstance = [self new];
	return sharedInstance;
}

- (id)init
{
	if(self = [super init])
	{
		_installDirectory = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"OakMate/Managed"];
		_localIndexPath   = [_installDirectory stringByAppendingPathComponent:@"LocalIndex.plist"];
		_remoteIndexPath  = [_installDirectory stringByAppendingPathComponent:@"Cache/org.textmate.updates.default"];
		_remoteIndexURL   = [NSURL URLWithString:@REST_API "/bundles"];

		[self userDefaultsDidChange:nil];
		OakObserveUserDefaults(self);
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:NSApp];
	}
	return self;
}

- (void)userDefaultsDidChange:(id)sender
{
	self.autoUpdateBundles = ![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsDisableBundleUpdatesKey];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	if(self.needsSaveBundlesIndex)
		[self saveBundlesIndex:self];
}

- (void)setAutoUpdateBundles:(BOOL)flag
{
	if(_autoUpdateBundles == flag)
		return;

	[_updateBundleIndexScheduler invalidate];
	_updateBundleIndexScheduler = nil;

	_autoUpdateBundles = flag;
	if(_autoUpdateBundles)
	{
		CGFloat updateFrequency = [NSUserDefaults.standardUserDefaults floatForKey:kUserDefaultsBundleUpdateFrequencyKey] ?: kDefaultPollInterval;

		_updateBundleIndexScheduler = [[NSBackgroundActivityScheduler alloc] initWithIdentifier:[NSString stringWithFormat:@"%@.%@", NSBundle.mainBundle.bundleIdentifier, @"UpdateBundleIndex"]];
		_updateBundleIndexScheduler.interval = updateFrequency;
		_updateBundleIndexScheduler.repeats  = YES;
		[_updateBundleIndexScheduler scheduleWithBlock:^(NSBackgroundActivityCompletionHandler completionHandler){
			os_activity_initiate("Update bundle index", OS_ACTIVITY_FLAG_DEFAULT, ^(){
				[self tryUpdateBundleIndexAndCallback:^(BOOL wasUpdated){
					os_log(OS_LOG_DEFAULT, "Newer bundle index retrieved: %{public}s", wasUpdated ? "YES" : "NO");
					completionHandler(NSBackgroundActivityResultFinished);
				}];
			});
		}];
	}
}

- (void)tryUpdateBundleIndexAndCallback:(void(^)(BOOL wasUpdated))completionHandler
{
	[OakDownloadManager.sharedInstance downloadFileAtURL:_remoteIndexURL replacingFileAtURL:[NSURL fileURLWithPath:_remoteIndexPath] completionHandler:^(BOOL wasUpdated, NSError* error){
		path::set_attr(_remoteIndexPath.fileSystemRepresentation, "last-check", to_s(oak::date_t::now()));
		if(!error)
			[NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:kUserDefaultsLastBundleUpdateCheckKey];
		if(wasUpdated)
		{
			os_log(OS_LOG_DEFAULT, "Bundle index updated: %{public}@", _remoteIndexPath);
			dispatch_async(dispatch_get_main_queue(), ^{
				if(NSArray* newBundles = [self bundlesByLoadingIndex])
				{
					NSSet* oldRecommendations = [NSSet setWithArray:[self.bundles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isRecommended == YES"]]];
					self.bundles = newBundles;
					NSArray* bundlesToUpdate = [newBundles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(hasUpdate == YES AND isCompatible == YES) OR (isInstalled == NO AND (isMandatory == YES OR (isRecommended == YES AND isCompatible == YES AND NOT (SELF IN %@))))", oldRecommendations]];
					[self installBundles:bundlesToUpdate completionHandler:^(NSArray<Bundle*>* updatedBundles){
						for(Bundle* bundle in updatedBundles)
							os_log(OS_LOG_DEFAULT, "%{public}@ bundle updated: %{public}@", bundle.name, bundle.path);
						completionHandler(wasUpdated);
					}];
				}
				else
				{
					completionHandler(wasUpdated);
				}
			});
		}
		else
		{
			if(error)
				os_log_error(OS_LOG_DEFAULT, "Failed to update bundle index: %{public}@", error.localizedDescription);
			completionHandler(wasUpdated);
		}
	}];
}

- (void)installBundleItemsAtPaths:(NSArray*)somePaths
{
	InstallBundleItems(somePaths);
}

- (BOOL)findBundleForInstall:(bundles::item_ptr*)res
{
	oak::uuid_t defaultBundle;

	passwd* entry = path::passwd_entry();
	std::string const personalBundleName = format_string::expand("${TM_FULLNAME/^(\\S+).*$/$1/}’s Bundle", std::map<std::string, std::string>{ { "TM_FULLNAME", entry && entry->pw_gecos ? entry->pw_gecos : "John Doe" } });
	for(auto item : bundles::query(bundles::kFieldName, personalBundleName, scope::wildcard, bundles::kItemTypeBundle))
		defaultBundle = item->uuid();

	NSPopUpButton* bundleChooser = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[bundleChooser.menu removeAllItems];
	[bundleChooser.menu addItemWithTitle:@"Create new bundle…" action:NULL keyEquivalent:@""];
	[bundleChooser.menu addItem:[NSMenuItem separatorItem]];

	std::multimap<std::string, bundles::item_ptr, text::less_t> ordered;
	for(auto item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle))
		ordered.emplace(item->name(), item);

	for(auto pair : ordered)
	{
		NSMenuItem* menuItem = [bundleChooser.menu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:NULL keyEquivalent:@""];
		[menuItem setRepresentedObject:[NSString stringWithCxxString:to_s(pair.second->uuid())]];
		if(defaultBundle && defaultBundle == pair.second->uuid())
			[bundleChooser selectItem:menuItem];
	}

	[bundleChooser sizeToFit];
	NSRect frame = [bundleChooser frame];
	if(NSWidth(frame) > 200)
		[bundleChooser setFrameSize:NSMakeSize(200, NSHeight(frame))];

	NSAlert* alert = [NSAlert tmAlertWithMessageText:@"Select Bundle" informativeText:@"Select the bundle which should be used for the new item(s)." buttons:@"OK", @"Cancel", nil];
	[alert setAccessoryView:bundleChooser];
	if([alert runModal] == NSAlertFirstButtonReturn) // "OK"
	{
		if(NSString* bundleUUID = [[bundleChooser selectedItem] representedObject])
		{
			for(auto item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle, to_s(bundleUUID)))
			{
				*res = item;
				return YES;
			}
		}
		else
		{
			NSAlert* alert        = [[NSAlert alloc] init];
			alert.messageText     = @"Creating bundles is not yet supported.";
			alert.informativeText = @"You can create a new bundle in the bundle editor via File → New (⌘N) and then repeat the previous action.";
			[alert addButtonWithTitle:@"OK"];
			[alert runModal];
		}
	}
	return NO;
}

- (NSProgress*)installBundles:(NSArray<Bundle*>*)someBundles completionHandler:(void(^)(NSArray<Bundle*>*))callback
{
	NSMutableSet* bundlesToInstall = [NSMutableSet set];

	NSMutableArray* queue = [someBundles mutableCopy];
	while(Bundle* bundle = [queue lastObject])
	{
		[bundlesToInstall addObject:bundle];
		NSArray* dependencies = [bundle.dependencies filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isInstalled == NO AND NOT (SELF IN %@)", bundlesToInstall]];
		[dependencies enumerateObjectsUsingBlock:^(Bundle* bundle, NSUInteger, BOOL*){ bundle.dependency = YES; }];
		[queue replaceObjectsInRange:NSMakeRange(queue.count-1, 1) withObjectsFromArray:dependencies];
	}

	if([bundlesToInstall count] == 0)
		return callback(nil), nil;

	NSString* bundlesDirectory = [_installDirectory stringByAppendingPathComponent:@"Bundles"];
	NSError* error;
	if(![NSFileManager.defaultManager createDirectoryAtPath:bundlesDirectory withIntermediateDirectories:YES attributes:nil error:&error])
	{
		os_log_error(OS_LOG_DEFAULT, "Failed to create directory %{public}@: %{public}@", bundlesDirectory, error.localizedDescription);
		return callback(nil), nil;
	}

	dispatch_group_t group = dispatch_group_create();
	NSArray* bundles = bundlesToInstall.allObjects;
	NSProgress* progress = [NSProgress discreteProgressWithTotalUnitCount:bundles.count];
	__block std::vector<std::string> res(bundles.count);
	for(NSUInteger i = 0; i < bundles.count; ++i)
	{
		dispatch_group_enter(group);

		Bundle* bundle = bundles[i];
		NSURL* destURL = [NSURL fileURLWithPath:bundle.path ?: [[bundlesDirectory stringByAppendingPathComponent:SafeBasename(bundle.name)] stringByAppendingPathExtension:@"tmbundle"] isDirectory:YES];
		os_log(OS_LOG_DEFAULT, "Download %{public}@ as %{public}@", bundle.downloadURL, destURL.path);

		[progress becomeCurrentWithPendingUnitCount:1];
		[OakDownloadManager.sharedInstance downloadArchiveAtURL:bundle.downloadURL forReplacingURL:destURL completionHandler:^(NSURL* extractedArchiveURL, NSError* error){
			if(extractedArchiveURL)
			{
				NSError* error;
				if([NSFileManager.defaultManager replaceItemAtURL:destURL withItemAtURL:extractedArchiveURL backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:&error])
				{
					res[i] = destURL.fileSystemRepresentation;
					os_log(OS_LOG_DEFAULT, "Updated %{public}@", destURL.path);
				}
				else
				{
					os_log_error(OS_LOG_DEFAULT, "Failed to update %{public}@: %{public}@", destURL.path, error.localizedDescription);
				}
			}
			else
			{
				os_log_error(OS_LOG_DEFAULT, "Failed to download %{public}@: %{public}@", bundle.downloadURL, error.localizedDescription);
			}
			dispatch_group_leave(group);
		}];
		[progress resignCurrent];
	}

	dispatch_group_notify(group, dispatch_get_main_queue(), ^{
		for(NSUInteger i = 0; i < bundles.count; ++i)
		{
			if(res[i] == NULL_STR)
				continue;

			Bundle* bundle = bundles[i];
			bundle.installed   = YES;
			bundle.path        = to_ns(res[i]);
			bundle.lastUpdated = bundle.downloadLastUpdated;

			path::set_attr(res[i], kBundleAttributeUpdated, to_s(bundle.downloadLastUpdated));
			[self reloadPath:bundle.path recursive:YES];
		}

		[self createBundlesIndex:self];
		[self saveLocalIndex];

		callback(bundles);
	});
	return progress;
}

- (void)uninstallBundle:(Bundle*)bundle
{
	bundle.installed = NO;
	if(!bundle.path || ![NSFileManager.defaultManager removeItemAtPath:bundle.path error:nil])
		return;

	[self erasePath:bundle.path];

	bundle.path        = nil;
	bundle.lastUpdated = nil;

	// TODO Remove bundle’s dependencies

	[self saveLocalIndex];
}

// ===============================================
// = Creating Bundle Index and Handling FSEvents =
// ===============================================

- (void)createBundlesIndex:(id)sender
{
	if(_needsCreateBundlesIndex == NO)
		return;
	_needsCreateBundlesIndex = NO;

	auto pair = create_bundle_index(bundlesPaths, cache);
	bundles::set_index(pair.first, pair.second);

	std::set<std::string> newWatchList;
	for(auto path : bundlesPaths)
		cache.copy_heads_for_path(path, std::inserter(newWatchList, newWatchList.end()));
	[self updateWatchList:newWatchList];
}

- (void)saveBundlesIndex:(id)sender
{
	cache.cleanup(bundlesPaths);
	if(cache.dirty())
	{
		cache.save_binary(bundlesIndexPath);
		cache.set_dirty(false);
	}
	_needsSaveBundlesIndex = NO;
}

- (void)setNeedsCreateBundlesIndex:(BOOL)flag
{
	if(_needsCreateBundlesIndex != flag && (_needsCreateBundlesIndex = flag))
		[self performSelector:@selector(createBundlesIndex:) withObject:self afterDelay:0];
}

- (void)setNeedsSaveBundlesIndex:(BOOL)flag
{
	if(_needsSaveBundlesIndex != flag && (_needsSaveBundlesIndex = flag))
		[self performSelector:@selector(saveBundlesIndex:) withObject:self afterDelay:5];
}

- (void)setEventId:(uint64_t)anEventId forPath:(NSString*)aPath
{
	cache.set_event_id_for_path(anEventId, to_s(aPath));
	self.needsSaveBundlesIndex = YES;
}

- (void)updateWatchList:(std::set<std::string> const&)newWatchList
{
	struct callback_t : fs::event_callback_t
	{
		void set_replaying_history (bool flag, std::string const& observedPath, uint64_t eventId)
		{
			[BundlesManager.sharedInstance setEventId:eventId forPath:[NSString stringWithCxxString:observedPath]];
		}

		void did_change (std::string const& path, std::string const& observedPath, uint64_t eventId, bool recursive)
		{
			[BundlesManager.sharedInstance reloadPath:[NSString stringWithCxxString:path] recursive:recursive];
			[BundlesManager.sharedInstance setEventId:eventId forPath:[NSString stringWithCxxString:observedPath]];
		}
	};

	static callback_t callback;

	std::vector<std::string> pathsAdded, pathsRemoved;
	std::set_difference(watchList.begin(), watchList.end(), newWatchList.begin(), newWatchList.end(), back_inserter(pathsRemoved));
	std::set_difference(newWatchList.begin(), newWatchList.end(), watchList.begin(), watchList.end(), back_inserter(pathsAdded));

	watchList = newWatchList;

	for(auto path : pathsRemoved)
	{
		fs::unwatch(path, &callback);
	}

	for(auto path : pathsAdded)
	{
		fs::watch(path, &callback, cache.event_id_for_path(path) ?: FSEventsGetCurrentEventId(), 1);
	}
}

- (void)erasePath:(NSString*)aPath
{
	if(cache.erase(to_s(aPath)))
	{
		self.needsCreateBundlesIndex = YES;
		self.needsSaveBundlesIndex   = YES;
	}
}

- (void)reloadPath:(NSString*)aPath
{
	[self reloadPath:aPath recursive:NO];
}

- (void)reloadPath:(NSString*)aPath recursive:(BOOL)flag
{
	if(cache.reload(to_s(aPath), flag))
	{
		self.needsCreateBundlesIndex = YES;
		self.needsSaveBundlesIndex   = YES;
	}
}

namespace
{
	static std::string const kFieldChangedItems = "changed";
	static std::string const kFieldDeletedItems = "deleted";
	static std::string const kFieldMainMenu     = "mainMenu";

	static plist::dictionary_t prune_dictionary (plist::dictionary_t const& plist)
	{
		static auto const DesiredKeys = new std::set<std::string>{ bundles::kFieldName, bundles::kFieldKeyEquivalent, bundles::kFieldTabTrigger, bundles::kFieldScopeSelector, bundles::kFieldSemanticClass, bundles::kFieldContentMatch, bundles::kFieldGrammarFirstLineMatch, bundles::kFieldGrammarScope, bundles::kFieldGrammarInjectionSelector, bundles::kFieldDropExtension, bundles::kFieldGrammarExtension, bundles::kFieldSettingName, bundles::kFieldHideFromUser, bundles::kFieldIsDeleted, bundles::kFieldIsDisabled, bundles::kFieldRequiredItems, bundles::kFieldUUID, bundles::kFieldIsDelta, kFieldMainMenu, kFieldDeletedItems, kFieldChangedItems };

		plist::dictionary_t res;
		for(auto pair : plist)
		{
			if(DesiredKeys->find(pair.first) == DesiredKeys->end() && pair.first.find(bundles::kFieldSettingName) != 0)
				continue;

			if(pair.first == bundles::kFieldSettingName)
			{
				if(plist::dictionary_t const* dictionary = std::get_if<plist::dictionary_t>(&pair.second))
				{
					plist::array_t settings;
					for(auto const& settingsPair : *dictionary)
						settings.push_back(settingsPair.first);
					res.emplace(pair.first, settings);
				}
			}
			else if(pair.first == kFieldChangedItems)
			{
				if(plist::dictionary_t const* dictionary = std::get_if<plist::dictionary_t>(&pair.second))
					res.emplace(pair.first, prune_dictionary(*dictionary));
			}
			else
			{
				res.insert(pair);
			}
		}
		return res;
	}
}

- (void)loadBundlesIndex
{
	for(auto path : bundles::locations())
		bundlesPaths.push_back(path::join(path, "Bundles"));
	bundlesIndexPath = path::join(path::home(), "Library/Caches/org.oakmate.OakMate/BundlesIndex.binary");
	cache.set_content_filter(&prune_dictionary);
	cache.load_binary(bundlesIndexPath);

	_needsCreateBundlesIndex = YES;
	[self createBundlesIndex:self];
}

namespace
{
	static NSArray<Bundle*>* BundlesFromIndex (NSString* remoteIndexPath, NSString* localIndexPath, NSString* installDir, NSDictionary<NSUUID*, Bundle*>* cache = nil)
	{
		NSMutableDictionary* res = [NSMutableDictionary dictionary];

		// =====================
		// = Load Remote Index =
		// =====================

		NSMutableDictionary* dependencies   = [NSMutableDictionary dictionary];
		NSMutableDictionary* bundlesByScope = [NSMutableDictionary dictionary];

		for(NSDictionary* item in [[NSDictionary dictionaryWithContentsOfFile:remoteIndexPath] objectForKey:@"bundles"])
		{
			NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:item[@"uuid"]];
			Bundle* bundle = cache[identifier] ?: [[Bundle alloc] initWithIdentifier:identifier];

			bundle.name              = item[@"name"];
			bundle.minimumAppVersion = item[@"requires"];
			bundle.category          = item[@"category"];
			bundle.htmlURL           = [NSURL URLWithString:item[@"html_url"]];
			bundle.contactName       = item[@"contactName"];
			bundle.contactEmail      = to_ns(decode::rot13(to_s(item[@"contactEmailRot13"])));
			bundle.summary           = item[@"description"];
			bundle.recommended       = [item[@"isDefault"] boolValue];
			bundle.mandatory         = [item[@"isMandatory"] boolValue];

			NSDictionary* version = [item[@"versions"] firstObject];
			bundle.downloadURL         = [NSURL URLWithString:version[@"url"]];
			bundle.downloadLastUpdated = version[@"updated"];
			bundle.downloadSize        = [version[@"size"] intValue];

			NSMutableArray* grammars = [NSMutableArray array];
			for(NSDictionary* info in item[@"grammars"])
			{
				BundleGrammar* grammar = [[BundleGrammar alloc] init];
				grammar.bundle         = bundle;
				grammar.name           = info[@"name"];
				grammar.identifier     = [[NSUUID alloc] initWithUUIDString:info[@"uuid"]];
				grammar.fileType       = info[@"scope"];
				grammar.firstLineMatch = info[@"firstLineMatch"];
				grammar.filePatterns   = info[@"fileTypes"];
				[grammars addObject:grammar];

				bundlesByScope[grammar.fileType] = bundle;
			}
			bundle.grammars = [grammars copy];
			res[bundle.identifier] = bundle;

			if([item[@"dependencies"] count])
				dependencies[bundle.identifier] = item[@"dependencies"];
		}

		// ======================
		// = Setup Dependencies =
		// ======================

		for(NSUUID* uuid in dependencies)
		{
			Bundle* bundle = res[uuid];

			NSMutableArray* array = [NSMutableArray array];
			for(NSDictionary* info in dependencies[uuid])
			{
				if(NSString* scope = info[@"grammar"])
				{
					if(Bundle* otherBundle = bundlesByScope[scope])
							[array addObject:otherBundle];
					else	NSLog(@"%@: No bundle provides ‘%@’.", bundle.name, scope);
				}
				else if(NSString* uuid = info[@"uuid"])
				{
					if(Bundle* otherBundle = [res objectForKey:[[NSUUID alloc] initWithUUIDString:uuid]])
							[array addObject:otherBundle];
					else	NSLog(@"%@: Required bundle not found ‘%@’ (%@).", bundle.name, info[@"name"], uuid);
				}
			}

			bundle.dependencies = [array copy];
		}

		// ====================
		// = Load Local Index =
		// ====================

		for(NSDictionary* item in [[NSDictionary dictionaryWithContentsOfFile:localIndexPath] objectForKey:@"bundles"])
		{
			NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:item[@"uuid"]];
			Bundle* bundle = res[identifier] ?: [[Bundle alloc] initWithIdentifier:identifier];

			bundle.installed   = YES;
			bundle.path        = [installDir stringByAppendingPathComponent:item[@"path"]];
			bundle.category    = item[@"category"] ?: bundle.category ?: @"Discontinued";
			bundle.lastUpdated = item[@"updated"];
			bundle.dependency  = [item[@"isDependency"] boolValue];

			res[bundle.identifier] = bundle;
		}

		// ========================
		// = Load Bundles on Disk =
		// ========================

		NSMutableDictionary* bundlesByPath = [NSMutableDictionary dictionary];
		for(Bundle* bundle in [res allValues])
		{
			if(bundle.path)
				bundlesByPath[bundle.path] = bundle;
		}

		NSString* bundlesDir = [installDir stringByAppendingPathComponent:@"Bundles"];
		for(auto const& entry : path::entries(to_s(bundlesDir), "*.tm[Bb]undle"))
		{
			NSString* bundlePath = [bundlesDir stringByAppendingPathComponent:to_ns(entry->d_name)];
			if(Bundle* bundle = [bundlesByPath objectForKey:bundlePath])
			{
				[bundlesByPath removeObjectForKey:bundlePath];
				if(bundle.downloadURL) // We have category, description etc. from remote index
					continue;
			}

			if(NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]])
			{
				NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:info[@"uuid"]];
				Bundle* bundle = res[identifier] ?: [[Bundle alloc] initWithIdentifier:identifier];

				bundle.installed    = YES;
				bundle.path         = bundlePath;
				bundle.category     = bundle.category     ?: @"Orphaned";
				bundle.name         = bundle.name         ?: info[@"name"];
				bundle.contactName  = bundle.contactName  ?: info[@"contactName"];
				bundle.contactEmail = bundle.contactEmail ?: to_ns(decode::rot13(to_s(info[@"contactEmailRot13"])));
				bundle.summary      = bundle.summary      ?: info[@"description"];

				NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
				dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";
				if(NSString* str = to_ns(path::get_attr(to_s(bundlePath), kBundleAttributeUpdated)))
					bundle.lastUpdated = [dateFormatter dateFromString:str];

				res[bundle.identifier] = bundle;

				NSLog(@"Found: ‘%@’ missing in local index.", bundle.name);
			}
		}

		for(Bundle* bundle in [bundlesByPath allValues])
		{
			bundle.installed = NO;
			NSLog(@"Missing: ‘%@’ not on disk.", bundle.name);
		}

		return [[res allValues] sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCompare:)] ]];
	}
}


- (NSArray<Bundle*>*)bundles
{
	if(!_bundles)
		_bundles = [self bundlesByLoadingIndex];
	return _bundles;
}

- (NSArray<Bundle*>*)bundlesByLoadingIndex
{
	NSMutableDictionary* previousBundles = [NSMutableDictionary dictionary];
	for(Bundle* bundle : _bundles)
		previousBundles[bundle.identifier] = bundle;
	return BundlesFromIndex(_remoteIndexPath, _localIndexPath, _installDirectory, previousBundles);
}

- (void)saveLocalIndex
{
	if(!_bundles)
		return;

	NSMutableArray* bundles = [NSMutableArray array];
	for(Bundle* bundle : [_bundles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isInstalled == YES AND path != NULL"]])
	{
		NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:@{
			@"uuid": [bundle.identifier UUIDString],
			@"path": [bundle.path stringByReplacingOccurrencesOfString:[_installDirectory stringByAppendingString:@"/"] withString:@""],
		}];

		if(bundle.lastUpdated)
			dict[@"updated"]  = bundle.lastUpdated;
		if(bundle.isDependency)
			dict[@"isDependency"] = @YES;
		if(bundle.category)
			dict[@"category"] = bundle.category;

		[bundles addObject:dict];
	}

	NSDictionary* plist = @{ @"bundles": bundles };
	[plist writeToFile:_localIndexPath atomically:YES];
}
@end
