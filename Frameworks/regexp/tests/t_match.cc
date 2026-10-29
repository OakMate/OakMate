#include <regexp/regexp.h>

void test_match ()
{
	std::string const str = " foo bar fud";
	regexp::match_t const match = regexp::search("(\\w+)\\s+(\\w+)", str);
	OAK_ASSERT(match);
	OAK_ASSERT_EQ(match[0], "foo bar");
	OAK_ASSERT_EQ(match[1], "foo");
	OAK_ASSERT_EQ(match[2], "bar");
	OAK_ASSERT_EQ(match[3], NULL_STR);
}
