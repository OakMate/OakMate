#include "CGColorRefToString.h"
#include <theme/theme.h>

void test_missing_theme_item_still_sets_gutter_colors ()
{
	bundles::item_ptr themeItem;
	theme_t theme(themeItem);
	auto const& gutter = theme.gutter_styles();
	OAK_ASSERT_EQ(to_s(gutter.divider.get()),               "#666666FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionBorder.get()),       "#666666FF");
	OAK_ASSERT_EQ(to_s(gutter.foreground.get()),            "#808080FF");
	OAK_ASSERT_EQ(to_s(gutter.background.get()),            "#212121FF");
	OAK_ASSERT_EQ(to_s(gutter.icons.get()),                 "#808080FF");
	OAK_ASSERT_EQ(to_s(gutter.iconsHover.get()),            "#808080FF");
	OAK_ASSERT_EQ(to_s(gutter.iconsPressed.get()),          "#808080FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionForeground.get()),   "#F2F2F2FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionBackground.get()),   "#0D0D0DFF");
	OAK_ASSERT_EQ(to_s(gutter.selectionIcons.get()),        "#F2F2F2FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionIconsHover.get()),   "#F2F2F2FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionIconsPressed.get()), "#F2F2F2FF");
}

static bundles::item_ptr make_theme_item (plist::dictionary_t const& plist)
{
	auto item = std::make_shared<bundles::item_t>(oak::uuid_t().generate(), bundles::item_ptr(), bundles::kItemTypeTheme);
	item->set_plist(plist);
	return item;
}

void test_gutter_settings_override_defaults ()
{
	plist::dictionary_t gutterSettings = {
		{ "divider",    std::string("#FF0000") },
		{ "foreground", std::string("#00FF0080") },
	};
	theme_t theme(make_theme_item({ { "gutterSettings", gutterSettings } }));
	auto const& gutter = theme.gutter_styles();
	OAK_ASSERT_EQ(to_s(gutter.divider.get()),         "#FF0000FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionBorder.get()), "#FF0000FF");
	OAK_ASSERT_EQ(to_s(gutter.foreground.get()),      "#00FF0080");
	OAK_ASSERT_EQ(to_s(gutter.icons.get()),           "#00FF0080");
}

void test_invalid_gutter_color_keeps_default ()
{
	plist::dictionary_t gutterSettings = {
		{ "divider",    std::string("red") },
		{ "background", std::string("") },
	};
	theme_t theme(make_theme_item({ { "gutterSettings", gutterSettings } }));
	auto const& gutter = theme.gutter_styles();
	OAK_ASSERT_EQ(to_s(gutter.divider.get()),         "#666666FF");
	OAK_ASSERT_EQ(to_s(gutter.selectionBorder.get()), "#666666FF");
	OAK_ASSERT_EQ(to_s(gutter.background.get()),      "#212121FF");
}

void test_parse_font_size ()
{
	OAK_ASSERT_EQ(parse_font_size(NULL_STR),  -1.0);
	OAK_ASSERT_EQ(parse_font_size("13"),      13.0);
	OAK_ASSERT_EQ(parse_font_size("12.5pt"),  12.5);
	OAK_ASSERT_EQ(parse_font_size("1.5em"),   -1.5);
	OAK_ASSERT_EQ(parse_font_size("150%"),    -1.5);
	OAK_ASSERT_EQ(parse_font_size("10 px"),   -1.0);
	OAK_ASSERT_EQ(parse_font_size("large"),   -1.0);
}
