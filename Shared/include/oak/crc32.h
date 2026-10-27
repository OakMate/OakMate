#ifndef OAK_CRC32_H_W4KQ9ZTB
#define OAK_CRC32_H_W4KQ9ZTB

#include <zlib.h>
#include <algorithm>
#include <cstdint>

namespace oak
{
	// Standard CRC-32 (same polynomial and result as zlib, PNG, and boost::crc_32_type)
	struct crc32_t
	{
		void process_bytes (void const* bytes, size_t len)
		{
			for(char const* it = (char const*)bytes; len; )
			{
				uInt chunk = (uInt)std::min<size_t>(len, UINT32_MAX);
				_crc = ::crc32(_crc, (Bytef const*)it, chunk);
				it  += chunk;
				len -= chunk;
			}
		}

		uint32_t checksum () const { return (uint32_t)_crc; }

	private:
		uLong _crc = ::crc32(0L, Z_NULL, 0);
	};

} /* oak */

#endif /* end of include guard: OAK_CRC32_H_W4KQ9ZTB */
