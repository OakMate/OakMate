#import <OSAKit/OSAKit.h>
#import "render.h"
#import <buffer/buffer.h>
#import <bundles/bundles.h>
#import <file/bytes.h>
#import <file/type.h>
#import <file/reader.h>
#import <io/path.h>
#import <cf/cf.h>
#import <ns/ns.h>
#import <oak/misc.h>
#import <plist/fs_cache.h>
#import <scope/scope.h>
#import <settings/settings.h>
#import <theme/theme.h>
#import <OakFoundation/NSString Additions.h>
#import <OakSystem/application.h>

static void initialize ()
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// The extension is located in TextMate.app/Contents/PlugIns
		NSString* appPath = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
		oak::application_t::set_path(to_s(appPath));

		// Load settings
		settings_t::set_default_settings_path(oak::application_t::path("Contents/Resources/Default.tmProperties"));
		settings_t::set_global_settings_path(path::join(path::home(), "Library/Application Support/TextMate/Global.tmProperties"));

		// Load bundle index
		std::vector<std::string> paths;
		for(auto path : bundles::locations())
			paths.push_back(path::join(path, "Bundles"));

		plist::cache_t cache;
		cache.load_binary(path::join(path::home(), "Library/Caches/com.macromates.TextMate/BundlesIndex.binary"));

		auto index = create_bundle_index(paths, cache);
		bundles::set_index(index.first, index.second);
	});
}

static std::string setup_buffer (NSURL* url, ng::buffer_t& buffer, size_t maxSize, size_t maxLines = SIZE_T_MAX)
{
	std::string filePath = to_s(url.filePathURL.path);

	std::string fileContents = NULL_STR;
	if(path::extension(filePath) == ".scpt")
	{
		@autoreleasepool {
			NSDictionary* err = nil;
			if(OSAScript* script = [[OSAScript alloc] initWithContentsOfURL:url error:&err])
			{
				fileContents = [[script source] UTF8String] ?: NULL_STR;
				std::replace(fileContents.begin(), fileContents.end(), '\r', '\n');
			}
		}
	}

	if(fileContents == NULL_STR)
		fileContents = file::read_utf8(filePath, nullptr, maxSize);

	if(maxLines != SIZE_T_MAX)
		fileContents.erase(std::find_if(fileContents.begin(), fileContents.end(), [&maxLines](char ch) { return ch == '\n' && --maxLines == 0; }), fileContents.end());

	buffer.insert(0, fileContents);

	// Apply appropriate grammar
	std::string fileType = file::type(filePath, std::make_shared<io::bytes_t>(fileContents.data(), fileContents.size(), false));
	if(fileType != NULL_STR)
	{
		for(auto item : bundles::query(bundles::kFieldGrammarScope, fileType, scope::wildcard, bundles::kItemTypeGrammar))
		{
			buffer.set_grammar(item);
			break;
		}
	}

	return fileType;
}

static NSAttributedString* create_attributed_string (ng::buffer_t& buffer, std::string const& themeUUID, std::string const& fontName, size_t fontSize, theme_ptr* themeOut = nullptr)
{
	if(themeUUID == NULL_STR || fontName == NULL_STR || fontSize == 0)
		return nil;

	bundles::item_ptr themeItem = bundles::lookup(themeUUID);
	if(!themeItem)
		return nil;

	theme_ptr theme = parse_theme(themeItem);
	if(!theme)
		return nil;

	theme = theme->copy_with_font_name_and_size(fontName, fontSize);
	if(themeOut)
		*themeOut = theme;

	// Perform syntax highlighting
	buffer.wait_for_repair();
	std::map<size_t, scope::scope_t> scopes = buffer.scopes(0, buffer.size());

	// Construct RTF output
	NSMutableAttributedString* output = (__bridge_transfer NSMutableAttributedString*)CFAttributedStringCreateMutable(kCFAllocatorDefault, buffer.size());
	size_t from = 0;
	for(auto pair = scopes.begin(); pair != scopes.end(); )
	{
		styles_t styles = theme->styles_for_scope(pair->second);

		size_t to = ++pair != scopes.end() ? pair->first : buffer.size();

		[output appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithCxxString:buffer.substr(from, to)] attributes:@{
			NSForegroundColorAttributeName:    [NSColor colorWithCGColor:styles.foreground()],
			NSBackgroundColorAttributeName:    [NSColor colorWithCGColor:styles.background()],
			NSFontAttributeName:               (__bridge NSFont*)styles.font(),
			NSUnderlineStyleAttributeName:     @(styles.underlined() ? NSUnderlineStyleSingle : NSUnderlineStyleNone),
			NSStrikethroughStyleAttributeName: @(styles.strikethrough() ? NSUnderlineStyleSingle : NSUnderlineStyleNone),
		}]];

		from = to;
	}

	return output;
}

// =============
// = Interface =
// =============

NSAttributedString* TMQLCreatePreview (NSURL* url, NSColor** backgroundColor)
{
	initialize();

	ng::buffer_t buffer;
	std::string fileType = setup_buffer(url, buffer, 20480);
	if(fileType == NULL_STR)
		fileType = "text.plain";

	NSUserDefaults* userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.macromates.TextMate"];
	NSString* appearance = [userDefaults stringForKey:@"themeAppearance"];
	BOOL darkMode = [appearance isEqualToString:@"dark"];
	if(!darkMode && ![appearance isEqualToString:@"light"]) // If it is not ‘light’ then assume ‘auto’
		darkMode = [[NSUserDefaults.standardUserDefaults stringForKey:@"AppleInterfaceStyle"] isEqualToString:@"Dark"];
	NSString* themeUUID = [userDefaults stringForKey:darkMode ? @"darkModeThemeUUID" : @"universalThemeUUID"] ?: (darkMode ? @(kTwilightThemeUUID) : @(kMacClassicThemeUUID));

	settings_t const settings = settings_for_path(to_s(url.filePathURL.path), fileType);
	theme_ptr theme;
	NSFont* font = [NSFont userFixedPitchFontOfSize:0];
	NSAttributedString* res = create_attributed_string(buffer, to_s(themeUUID), settings.get(kSettingsFontNameKey, to_s([font fontName])), settings.get(kSettingsFontSizeKey, [font pointSize]), &theme);
	if(res && backgroundColor)
		*backgroundColor = [NSColor colorWithCGColor:theme->background(fileType)];
	return res;
}

NSAttributedString* TMQLCreateThumbnail (NSURL* url, CGFloat fontSize, size_t maxLines)
{
	initialize();

	ng::buffer_t buffer;
	setup_buffer(url, buffer, 4096, maxLines);

	NSFont* font = [NSFont userFixedPitchFontOfSize:fontSize];
	return create_attributed_string(buffer, kMacClassicThemeUUID, to_s([font fontName]), [font pointSize]);
}
