#ifndef PLIST_H_34L7NUFO
#define PLIST_H_34L7NUFO

#include "date.h"
#include "uuid.h"
#include <text/format.h>
#include <oak/debug.h>
#include <variant>

namespace plist
{
	struct any_t;

	typedef std::map<std::string, any_t> dictionary_t;
	typedef std::vector<any_t> array_t;

	struct any_t : std::variant<bool, int32_t, uint64_t, std::string, std::vector<char>, oak::date_t, array_t, dictionary_t>
	{
		using variant::variant;
	};

	enum plist_format_t { kPlistFormatBinary, kPlistFormatXML };

	dictionary_t load (std::string const& path);
	bool save (std::string const& path, any_t const& plist, plist_format_t format = kPlistFormatBinary);
	any_t parse (std::string const& str);
	dictionary_t convert (CFPropertyListRef plist);
	CFPropertyListRef create_cf_property_list (any_t const& plist);
	bool equal (any_t const& lhs, any_t const& rhs);

	bool is_true (any_t const& item);

	template <typename T> bool get_key_path (any_t const& plist, std::string const& keyPath, T& ref);
	template <typename T> T get (plist::any_t const& from);

	// to_s flags
	enum { kStandard = 0, kPreferSingleQuotedStrings = 1, kSingleLine = 2 };

	std::string to_s (any_t const& plist, int flags = kStandard, std::vector<std::string> const& keySortOrder = std::vector<std::string>());

} /* plist */

#endif /* end of include guard: PLIST_H_34L7NUFO */
