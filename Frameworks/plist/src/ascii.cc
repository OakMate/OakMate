#include "ascii.h"
#include <text/format.h>
#include <oak/debug.h>

/*
array:    '(' (element ',')* (element)? ')'
dict:     '{' (key '=' value ';')* '}'
integer:  ('-'|'+')? ('0x'|'0')? [0-9]+
float:    '-'? [0-9]* '.' [0-9]+
boolean:  :true | :false
string:   ["] … ["] | ['] … ['] | [a-zA-Z_-]+
data:     <DEADBEEF>
date:     @2010-05-10 20:34:12 +0000
*/

static bool backtrack (char const*& p, char const* bt, plist::any_t& res)
{
	return (res = plist::any_t()), (p = bt), false;
}

static bool parse_ws (char const*& p, char const* pe)
{
	static char const* const kCommentEnd = "*/";

	while(p != pe)
	{
		if(*p == ' ' || *p == '\t' || *p == '\n')
		{
			++p;
		}
		else if(*p == '/' && pe - p >= 2 && p[1] == '/')
		{
			p = std::find(p + 2, pe, '\n');
		}
		else if(*p == '/' && pe - p >= 2 && p[1] == '*')
		{
			p = std::search(p + 2, pe, kCommentEnd, kCommentEnd + 2);
			p = p == pe ? pe : p + 2;
		}
		else
		{
			break;
		}
	}
	return true;
}

static bool parse_char (char const*& p, char const*& pe, char ch)
{
	return parse_ws(p, pe) && p != pe && *p == ch ? (++p, true) : false;
}

static bool parse_int (char const*& p, char const* pe, plist::any_t& res)
{
	char const* bt = p;
	parse_ws(p, pe);
	if(p == pe || (!isdigit(*p) && *p != '-' && *p != '+'))
		return backtrack(p, bt, res);

	char* dummy;
	quad_t val = strtoq(p, &dummy, 0);
	p = dummy;
	if(std::clamp<quad_t>(val, INT32_MIN, INT32_MAX) == val)
			res = int32_t(val);
	else	res = uint64_t(val);

	return true;
}

static bool parse_bool (char const*& p, char const* pe, plist::any_t& res)
{
	char const* bt = p;
	parse_ws(p, pe);
	size_t bytes = pe - p;
	if(bytes >= 5 && strncmp(p, ":true", 5) == 0)
		return (res = true), (p += 5), true;
	if(bytes >= 6 && strncmp(p, ":false", 6) == 0)
		return (res = false), (p += 6), true;
	return backtrack(p, bt, res);
}

static bool is_bare_head (char ch) { return ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ch == '_'; }
static bool is_bare_tail (char ch) { return is_bare_head(ch) || ('0' <= ch && ch <= '9') || ch == '-' || ch == '.'; }

static bool parse_string (char const*& p, char const* pe, plist::any_t& res)
{
	char const* bt = p;
	parse_ws(p, pe);
	if(p == pe)
		return backtrack(p, bt, res);

	std::string str;
	if(is_bare_head(*p))
	{
		char const* first = p;
		while(p != pe && is_bare_tail(*p))
			++p;
		str.assign(first, p);
	}
	else if(*p == '\'') // single quoted: '' is an escaped quote
	{
		for(++p; true; ++p)
		{
			if(p == pe)
				return backtrack(p, bt, res);
			else if(*p != '\'')
				str.push_back(*p);
			else if(pe - p >= 2 && p[1] == '\'')
				str.push_back(*++p);
			else
				break;
		}
		++p;
	}
	else if(*p == '"') // double quoted: \\ and \" are unescaped, other escapes are kept verbatim
	{
		for(++p; true; ++p)
		{
			if(p == pe)
				return backtrack(p, bt, res);
			else if(*p == '"')
				break;
			else if(*p != '\\')
				str.push_back(*p);
			else if(++p == pe)
				return backtrack(p, bt, res);
			else if(*p == '\\' || *p == '"')
				str.push_back(*p);
			else
				str.append({ '\\', *p });
		}
		++p;
	}
	else
	{
		return backtrack(p, bt, res);
	}

	res = std::move(str);
	return true;
}

static bool parse_date (char const*& p, char const* pe, plist::any_t& res)
{
	char const* bt = p;
	if(!parse_char(p, pe, '@'))
		return backtrack(p, bt, res);

	size_t bytes = pe - p;
	if(bytes >= 25)
	{
		oak::date_t date(std::string(p, p + 25));
		if(date)
		{
			res = date;
			p += 25;
			return true;
		}
	}
	return backtrack(p, bt, res);
}

static bool parse_element (char const*& p, char const* pe, plist::any_t& res);

static bool parse_array (char const*& p, char const* pe, plist::any_t& res)
{
	// '(' (element ',')* (element)? ')'
	char const* bt = p;
	if(!parse_char(p, pe, '('))
		return backtrack(p, bt, res);

	plist::any_t element;
	std::vector<plist::any_t>& ref = std::get< std::vector<plist::any_t> >(res = std::vector<plist::any_t>());
	while(parse_element(p, pe, element))
	{
		ref.push_back(element);
		if(!parse_char(p, pe, ','))
			break;
	}
	return parse_char(p, pe, ')') || backtrack(p, bt, res);
}

static bool parse_key (char const*& p, char const* pe, plist::any_t& res)
{
	plist::any_t tmp;
	if(!parse_element(p, pe, tmp))
		return false;
	res = plist::get<std::string>(tmp);
	return !std::get<std::string>(res).empty();
}

static bool parse_dict (char const*& p, char const* pe, plist::any_t& res)
{
	// '{' (key '=' value ';')* '}'
	char const* bt = p;
	if(!parse_char(p, pe, '{'))
		return backtrack(p, bt, res);

	plist::any_t key, value;
	std::map<std::string, plist::any_t>& ref = std::get< std::map<std::string, plist::any_t> >(res = std::map<std::string, plist::any_t>());
	for(char const* lp = p; parse_key(lp, pe, key) && parse_char(lp, pe, '=') && parse_element(lp, pe, value) && parse_char(lp, pe, ';'); p = lp)
		ref.emplace(std::get<std::string>(key), value);

	return parse_char(p, pe, '}') || backtrack(p, bt, res);
}

static bool parse_element (char const*& p, char const* pe, plist::any_t& res)
{
	return parse_string(p, pe, res) || parse_int(p, pe, res) || parse_bool(p, pe, res) || parse_date(p, pe, res) || parse_dict(p, pe, res) || parse_array(p, pe, res);
}

namespace plist
{
	plist::any_t parse_ascii (std::string const& str, bool* success)
	{
		plist::any_t res;
		char const* p  = str.data();
		char const* pe = p + str.size();
		bool didParse = parse_element(p, pe, res) && parse_ws(p, pe) && p == pe;
		if(success)
			*success = didParse;
		return didParse ? res : plist::any_t();
	}

} /* plist */
