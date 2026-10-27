#ifndef OAK_SERIALIZE_H_P7XN2C4M
#define OAK_SERIALIZE_H_P7XN2C4M

#include <string>
#include <cstring>
#include <cstdint>
#include <stdexcept>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

namespace oak
{
	// Minimal little-endian binary format used for TextMate’s cache files.
	// Files start with a 4 byte magic followed by a uint32 format version.

	struct binary_writer_t
	{
		binary_writer_t (char const magic[4], uint32_t version)
		{
			_buffer.append(magic, 4);
			u32(version);
		}

		void u8 (uint8_t value)                     { _buffer.push_back((char)value); }
		void u32 (uint32_t value)                   { raw(&value, sizeof(value)); }
		void u64 (uint64_t value)                   { raw(&value, sizeof(value)); }
		void f64 (double value)                     { raw(&value, sizeof(value)); }
		void bytes (void const* data, size_t len)   { varint(len); raw(data, len); }
		void string (std::string const& str)        { bytes(str.data(), str.size()); }

		void varint (uint64_t value)
		{
			while(value >= 0x80)
			{
				_buffer.push_back((char)(value | 0x80));
				value >>= 7;
			}
			_buffer.push_back((char)value);
		}

		std::string const& data () const { return _buffer; }

		// Writes to a temporary file which is then renamed, so readers never see a partial file
		bool write_to_file (std::string const& path) const
		{
			std::string const tmp = path + ".tmp";
			int fd = open(tmp.c_str(), O_CREAT|O_TRUNC|O_WRONLY|O_CLOEXEC, S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH);
			if(fd == -1)
				return false;

			bool success = true;
			for(size_t offset = 0; success && offset < _buffer.size(); )
			{
				ssize_t len = write(fd, _buffer.data() + offset, _buffer.size() - offset);
				if(len > 0)
					offset += len;
				else if(len == -1 && errno != EINTR)
					success = false;
			}

			success = close(fd) == 0 && success;
			if(success && rename(tmp.c_str(), path.c_str()) == 0)
				return true;

			unlink(tmp.c_str());
			return false;
		}

	private:
		void raw (void const* data, size_t len) { _buffer.append((char const*)data, len); }
		std::string _buffer;
	};

	struct binary_reader_t
	{
		// Throws std::runtime_error if the data does not start with the expected magic and version
		binary_reader_t (std::string data, char const magic[4], uint32_t version) : _buffer(std::move(data))
		{
			if(_buffer.size() < 4 || memcmp(_buffer.data(), magic, 4) != 0)
				throw std::runtime_error("unrecognized file format");
			_offset = 4;
			if(uint32_t actual = u32(); actual != version)
				throw std::runtime_error("unsupported format version " + std::to_string(actual) + " (expected " + std::to_string(version) + ")");
		}

		static bool read_file (std::string const& path, std::string& out)
		{
			int fd = open(path.c_str(), O_RDONLY|O_CLOEXEC);
			if(fd == -1)
				return false;

			out.clear();
			char buf[64*1024];
			ssize_t len;
			while((len = read(fd, buf, sizeof(buf))) > 0 || (len == -1 && errno == EINTR))
			{
				if(len > 0)
					out.append(buf, len);
			}
			close(fd);
			return len == 0;
		}

		uint8_t u8 ()       { uint8_t res;  raw(&res, sizeof(res)); return res; }
		uint32_t u32 ()     { uint32_t res; raw(&res, sizeof(res)); return res; }
		uint64_t u64 ()     { uint64_t res; raw(&res, sizeof(res)); return res; }
		double f64 ()       { double res;   raw(&res, sizeof(res)); return res; }

		uint64_t varint ()
		{
			uint64_t res = 0;
			for(size_t shift = 0; shift < 64; shift += 7)
			{
				uint8_t byte = u8();
				res |= uint64_t(byte & 0x7F) << shift;
				if((byte & 0x80) == 0)
					return res;
			}
			throw std::runtime_error("malformed varint");
		}

		// Element counts are bounded by the remaining bytes (every element takes at least one byte)
		size_t count ()
		{
			uint64_t res = varint();
			if(res > remaining())
				throw std::runtime_error("count exceeds data size");
			return res;
		}

		std::string string ()
		{
			size_t len = count();
			std::string res(_buffer.data() + _offset, len);
			_offset += len;
			return res;
		}

		size_t remaining () const { return _buffer.size() - _offset; }
		bool at_end () const      { return _offset == _buffer.size(); }

	private:
		void raw (void* dst, size_t len)
		{
			if(len > remaining())
				throw std::runtime_error("unexpected end of data");
			memcpy(dst, _buffer.data() + _offset, len);
			_offset += len;
		}

		std::string _buffer;
		size_t _offset = 0;
	};

} /* oak */

#endif /* end of include guard: OAK_SERIALIZE_H_P7XN2C4M */
