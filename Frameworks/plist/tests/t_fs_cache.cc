#include <plist/fs_cache.h>
#include <plist/plist.h>
#include <test/jail.h>

static plist::dictionary_t sample_plist ()
{
	plist::dictionary_t nested;
	nested["flag"]  = false;
	nested["empty"] = plist::array_t();

	plist::dictionary_t res;
	res["string"]  = std::string("Æblegrød…");
	res["integer"] = int32_t(-42);
	res["large"]   = uint64_t(1) << 40;
	res["boolean"] = true;
	res["date"]    = oak::date_t(time_t(1600000000));
	res["data"]    = std::vector<char>{ 'a', '\0', 'b' };
	res["array"]   = plist::array_t{ std::string("one"), int32_t(2), nested };
	res["nested"]  = nested;
	return res;
}

void test_binary_round_trip ()
{
	test::jail_t jail;
	jail.mkdir("Bundles/Test.tmbundle");
	plist::save(jail.path("Bundles/Test.tmbundle/info.plist"), sample_plist());
	jail.ln("Bundles/Link.tmbundle", "Bundles/Test.tmbundle");

	plist::cache_t cache;
	OAK_ASSERT_EQ(cache.entries(jail.path("Bundles")).size(), 2);
	OAK_ASSERT(plist::equal(cache.content(jail.path("Bundles/Test.tmbundle/info.plist")), sample_plist()));
	OAK_ASSERT_EQ(cache.entries(jail.path("Bundles/Link.tmbundle")), std::vector<std::string>{ jail.path("Bundles/Test.tmbundle/info.plist") });
	cache.set_event_id_for_path(1234, jail.path("Bundles"));

	std::string const indexPath = jail.path("index.binary");
	cache.save_binary(indexPath);

	// Remove the source so content must come from the loaded cache
	jail.remove("Bundles/Test.tmbundle/info.plist");

	plist::cache_t loaded;
	loaded.load_binary(indexPath);
	OAK_ASSERT(plist::equal(loaded.content(jail.path("Bundles/Test.tmbundle/info.plist")), sample_plist()));
	OAK_ASSERT_EQ(loaded.entries(jail.path("Bundles/Link.tmbundle")), std::vector<std::string>{ jail.path("Bundles/Test.tmbundle/info.plist") });
	OAK_ASSERT_EQ(loaded.entries(jail.path("Bundles")).size(), 2);
	OAK_ASSERT_EQ(loaded.event_id_for_path(jail.path("Bundles")), 1234);
}

void test_binary_corrupt_input ()
{
	test::jail_t jail;
	plist::save(jail.path("info.plist"), sample_plist());

	plist::cache_t cache;
	cache.content(jail.path("info.plist"));
	cache.save_binary(jail.path("index.binary"));

	std::string const data = path::content(jail.path("index.binary"));
	for(size_t len : { size_t(0), size_t(3), size_t(8), data.size() / 2, data.size() - 1 })
	{
		jail.set_content("truncated.binary", data.substr(0, len));
		jail.remove("info.plist");

		plist::cache_t loaded;
		loaded.load_binary(jail.path("truncated.binary"));
		OAK_ASSERT(loaded.content(jail.path("info.plist")).empty());
	}
}
