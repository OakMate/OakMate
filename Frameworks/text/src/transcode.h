#ifndef TEXT_TRANSCODE_H_K3M8QZ2V
#define TEXT_TRANSCODE_H_K3M8QZ2V

#include <oak/debug.h>
#include <oak/misc.h>
#include <CoreFoundation/CoreFoundation.h>
#include <iconv.h>
#include <map>

namespace text
{
	struct transcode_t
	{
		transcode_t (std::string fromCharset, std::string toCharset)
		{
			std::string const kBOMCharacter = "\uFEFF";

			_buffer = new char[_buffer_size];
			reset_buffer();

			bool readBOM = false;
			fromCharset = parse_charset(fromCharset, &readBOM);
			if(readBOM)
			{
				if(auto bomWriter = transcode_t("UTF-8", fromCharset))
					bomWriter(kBOMCharacter.data(), kBOMCharacter.data() + kBOMCharacter.size(), back_inserter(_skip_prefix));
			}

			bool writeBOM = false;
			toCharset = parse_charset(toCharset, &writeBOM);
			if(writeBOM)
			{
				if(auto bomWriter = transcode_t("UTF-8", toCharset))
				{
					_dest = bomWriter(kBOMCharacter.data(), kBOMCharacter.data() + kBOMCharacter.size(), _dest);
					_left = _buffer_size - (_dest - _buffer);
				}
			}

			// Transliteration via iconv’s //TRANSLIT is unreliable on macOS 14+: Output is corrupted when several characters in one
			// call need multi-byte replacements (e.g. “Æød…” → “AEo......”) and opening a plain handle for the same charsets (anywhere
			// in the process) silently disables transliteration for existing handles. We therefore convert without //TRANSLIT and
			// transliterate unconvertible characters ourselves (see transliterate()). The same applies to //IGNORE: A handle opened
			// with it makes existing plain handles for the same charsets silently drop unconvertible characters, so we skip these ourselves.
			_ignore = parse_charset_option(toCharset, "//IGNORE");
			bool const translit = parse_charset_option(toCharset, "//TRANSLIT");
			if(translit || _ignore)
				_decode_handle = iconv_open("UTF-8", fromCharset.c_str());
			if(translit)
				_encode_handle = iconv_open(toCharset.c_str(), "UTF-8");

			// Invalid input is skipped one code unit at a time (e.g. 2 bytes for UTF-16) to not misalign the remaining input
			iconv_t unitHandle = _ignore ? iconv_open(fromCharset.c_str(), "UTF-8") : (iconv_t)-1;
			if(unitHandle != (iconv_t)-1)
			{
				std::string one, two;
				if(convert_all(unitHandle, "a", one) && convert_all(unitHandle, "aa", two) && two.size() > one.size())
					_unit_size = two.size() - one.size();
				iconv_close(unitHandle);
			}

			_handle = iconv_open(toCharset.c_str(), fromCharset.c_str());
			if(_handle == (iconv_t)-1)
				perrorf("transcode_t: iconv_open(\"%s\", \"%s\")", toCharset.c_str(), fromCharset.c_str());
		}

		~transcode_t ()
		{
			ASSERT_EQ(_left, _buffer_size);
			if(_handle != (iconv_t)-1)
				iconv_close(_handle);
			for(iconv_t handle : { _decode_handle, _encode_handle })
			{
				if(handle != (iconv_t)-1)
					iconv_close(handle);
			}
			delete[] _buffer;
		}

		operator bool () const
		{
			return _handle != (iconv_t)-1;
		}

		template <typename _OutputIter>
		_OutputIter operator() (_OutputIter out)
		{
			for(auto ch : _partial_sequence)
			{
				// This asserts that the output encoding is an ASCII superset
				int bytesWritten = std::min(snprintf(_dest, _left, "\\x%02X", ch), (int)_left);
				if(bytesWritten > 0)
				{
					_dest += bytesWritten;
					_left -= bytesWritten;
				}
			}
			_partial_sequence.clear();

			out = std::copy(_buffer, _dest, out);
			reset_buffer();
			return out;
		}

		template <typename _OutputIter>
		_OutputIter operator() (char const* first, char const* last, _OutputIter out)
		{
			ASSERT_NE(_handle, (iconv_t)-1);

			char* inBuf      = (char*)first;
			size_t inBufLeft = last - first;

			if(_skip_offset < _skip_prefix.size())
			{
				size_t len = std::min(_skip_prefix.size() - _skip_offset, inBufLeft);
				if(std::equal(inBuf, inBuf + len, _skip_prefix.data() + _skip_offset))
				{
					_skip_offset += len;
				}
				else
				{
					size_t oldOffset = _skip_offset;
					_skip_offset = _skip_prefix.size();
					out = (*this)(_skip_prefix.data(), _skip_prefix.data() + oldOffset + len, out);
				}

				inBuf        += len;
				inBufLeft    -= len;
			}

			while(inBufLeft)
			{
				size_t rc;
				if(_partial_sequence.empty())
				{
					rc = iconv(_handle, &inBuf, &inBufLeft, &_dest, &_left);
				}
				else
				{
					do {

						_partial_sequence.append(1, *inBuf++);
						inBufLeft -= 1;

						char* partialBuf      = (char*)_partial_sequence.data();
						size_t partialBufLeft = _partial_sequence.size();

						rc = iconv(_handle, &partialBuf, &partialBufLeft, &_dest, &_left);
						_partial_sequence.erase(0, _partial_sequence.size() - partialBufLeft);

						if(rc == (size_t)-1 && errno != EINVAL)
							break;

					} while(!_partial_sequence.empty() && inBufLeft);
				}

				out = std::copy(_buffer, _dest, out);
				reset_buffer();

				if(rc == (size_t)-1)
				{
					if(errno == EINVAL)
					{
						_partial_sequence.append(inBuf, inBufLeft);
						break;
					}
					else if(errno == EILSEQ)
					{
						if(_partial_sequence.empty() ? transliterate(inBuf, inBufLeft, out) : transliterate_partial_sequence(out))
							continue;

						if(_ignore)
						{
							if(_partial_sequence.empty())
							{
								size_t len = skip_length(inBuf, inBufLeft);
								inBuf     += len;
								inBufLeft -= len;
							}
							else // Skip the invalid prefix and convert the bytes following it
							{
								std::string const rest = _partial_sequence.substr(skip_length(_partial_sequence.data(), _partial_sequence.size()));
								_partial_sequence.clear();
								out = (*this)(rest.data(), rest.data() + rest.size(), out);
							}
							continue;
						}

						++_invalid_count;

						if(_partial_sequence.empty())
						{
							_partial_sequence.append(1, *inBuf++);
							--inBufLeft;
						}

						out = (*this)(out); // Force writing current partial sequence to ‘out’
					}
					else if(errno == E2BIG)
					{
						ASSERT_NE(_left, 0);
					}
					else
					{
						perror("transcode_t: iconv");
						break;
					}
				}
			}

			out = std::copy(_buffer, _dest, out);
			reset_buffer();

			return out;
		}

		size_t invalid_count () const { return _invalid_count; }

	private:
		static bool parse_charset_option (std::string& charset, std::string const& option)
		{
			auto it = std::search(charset.begin(), charset.end(), option.begin(), option.end(), [](char lhs, char rhs){ return toupper(lhs) == toupper(rhs); });
			if(it == charset.end())
				return false;
			charset.erase(it, it + option.size());
			return true;
		}

		std::string parse_charset (std::string charset, bool* bom)
		{
			if(parse_charset_option(charset, "//BOM") && bom)
				*bom = true;
			return charset;
		}

		// Convert all of ‘src’ (resetting state first), returns false if any of it could not be converted
		static bool convert_all (iconv_t handle, std::string const& src, std::string& dst)
		{
			char buf[256];
			char* inBuf      = (char*)src.data();
			size_t inBufLeft = src.size();

			iconv(handle, nullptr, nullptr, nullptr, nullptr);
			while(true)
			{
				char* outBuf      = buf;
				size_t outBufLeft = sizeof(buf);
				size_t rc = inBufLeft ? iconv(handle, &inBuf, &inBufLeft, &outBuf, &outBufLeft) : iconv(handle, nullptr, nullptr, &outBuf, &outBufLeft);
				dst.append(buf, outBuf);

				if(rc == (size_t)-1 && errno != E2BIG)
					return false;
				else if(rc != (size_t)-1 && inBufLeft == 0)
					return true;
			}
		}

		// Characters not handled by ICU’s Latin-ASCII transform (replacements match what iconv used to produce)
		static char const* symbol_transliteration (std::string const& utf8)
		{
			static std::map<std::string, char const*> const symbols = {
				{ "€", "EUR" }, { "£", "lb" }, { "¥", "yen" }, { "¢", "c" }, { "™", "TM" }, { "°", "^0" }, { "§", "SS" },
				{ "¶", "P" }, { "•", "o" }, { "·", "." }, { "‰", "o/oo" }, { "µ", "u" }, { "¬", "not" }, { "¦", "|" },
				{ "≠", "/=" }, { "≤", "<=" }, { "≥", ">=" }, { "ª", "a" }, { "º", "o" }, { "¹", "^1" }, { "²", "^2" }, { "³", "^3" },
			};
			auto it = symbols.find(utf8);
			return it != symbols.end() ? it->second : nullptr;
		}

		static std::string ascii_transliteration (std::string const& utf8)
		{
			if(char const* symbol = symbol_transliteration(utf8))
				return symbol;

			std::string res = utf8;
			if(CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault, (UInt8 const*)utf8.data(), utf8.size(), kCFStringEncodingUTF8, false))
			{
				if(CFMutableStringRef tmp = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, str))
				{
					if(CFStringTransform(tmp, nullptr, CFSTR("Any-Latin; Latin-ASCII"), false))
					{
						CFIndex len = 0, length = CFStringGetLength(tmp);
						CFStringGetBytes(tmp, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, false, nullptr, 0, &len);
						res.resize(len);
						CFStringGetBytes(tmp, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, false, (UInt8*)res.data(), len, nullptr);
					}
					CFRelease(tmp);
				}
				CFRelease(str);
			}
			return res;
		}

		// Decode the single character at the start of ‘buf’ to UTF-8, returns its length or 0 if the input is invalid
		size_t decode_character (char const* buf, size_t bufLeft, std::string& utf8)
		{
			if(_decode_handle == (iconv_t)-1)
				return 0;

			// Find the length of the character by decoding increasingly longer prefixes
			for(size_t len = 1; len <= std::min<size_t>(bufLeft, 8); ++len)
			{
				utf8.clear();
				if(convert_all(_decode_handle, std::string(buf, len), utf8))
					return len;
				else if(errno != EINVAL)
					break;
			}
			return 0;
		}

		// Number of bytes to skip for //IGNORE: The full (unconvertible) character, or a single code unit of invalid input
		size_t skip_length (char const* buf, size_t bufLeft)
		{
			std::string utf8;
			if(size_t len = decode_character(buf, bufLeft, utf8))
				return len;
			return std::min(_unit_size, bufLeft);
		}

		// Transliterate the single (unconvertible) character at the start of ‘inBuf’
		template <typename _OutputIter>
		bool transliterate (char*& inBuf, size_t& inBufLeft, _OutputIter& out)
		{
			if(_encode_handle == (iconv_t)-1)
				return false;

			std::string utf8;
			size_t len = decode_character(inBuf, inBufLeft, utf8);
			if(len == 0)
				return false;

			std::string dst, tmp;
			auto convert = [&](iconv_t handle, std::string const& src){
				tmp.clear();
				return handle != (iconv_t)-1 && convert_all(handle, src, tmp) && (dst += tmp, true);
			};

			for(char const* it = utf8.data(), *last = it + utf8.size(); it != last; )
			{
				std::string const original(it, std::find_if(it + 1, last, [](char ch){ return (ch & 0xC0) != 0x80; }));
				it += original.size();

				// Use ‘?’ for characters without transliteration (same as iconv) unless these should be ignored
				if(!convert(_encode_handle, ascii_transliteration(original)) && !_ignore)
					convert(_encode_handle, "?");
			}

			out = std::copy(dst.begin(), dst.end(), out);
			inBuf     += len;
			inBufLeft -= len;
			return true;
		}

		template <typename _OutputIter>
		bool transliterate_partial_sequence (_OutputIter& out)
		{
			char* buf  = (char*)_partial_sequence.data();
			size_t len = _partial_sequence.size();
			if(!transliterate(buf, len, out))
				return false;
			_partial_sequence.erase(0, _partial_sequence.size() - len);
			return true;
		}

		void reset_buffer ()
		{
			_dest = _buffer;
			_left = _buffer_size;
		}

		iconv_t _handle = (iconv_t)-1;
		iconv_t _decode_handle = (iconv_t)-1;
		iconv_t _encode_handle = (iconv_t)-1;
		size_t _invalid_count = 0;
		bool _ignore = false;
		size_t _unit_size = 1;

		std::string _skip_prefix;
		size_t _skip_offset = 0;

		std::string _partial_sequence;

		char* _buffer;
		size_t _buffer_size = 4096;

		char* _dest;
		size_t _left;
	};

} /* text */

#endif /* end of include guard: TEXT_TRANSCODE_H_K3M8QZ2V */
