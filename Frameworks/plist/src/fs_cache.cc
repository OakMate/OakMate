#include "fs_cache.h"
#include <oak/serialize.h>
#include <io/entries.h>
#include <text/format.h>
#include <oak/debug.h>

static std::string read_link (std::string const& path)
{
	char buf[PATH_MAX];
	ssize_t len = readlink(path.c_str(), buf, sizeof(buf));
	if(0 < len && len < PATH_MAX)
	{
		return std::string(buf, buf + len);
	}
	else
	{
		std::string errStr = len == -1 ? strerror(errno) : text::format("Result outside allowed range %zd", len);
		os_log_error(OS_LOG_DEFAULT, "readlink(\"%{public}s\"): %{public}s", path.c_str(), errStr.c_str());
	}
	return NULL_STR;
}

namespace
{
	char const kBinaryCacheMagic[4] = { 'T', 'M', 'B', 'I' };
	uint32_t const kBinaryCacheFormatVersion = 3;

	enum : uint8_t { kBinaryEntryFile, kBinaryEntryDirectory, kBinaryEntryLink, kBinaryEntryMissing };

	// Tags are the index of the type in plist::any_t
	struct write_any_t
	{
		oak::binary_writer_t& writer;

		void operator() (bool flag) const                        { writer.u8(flag ? 1 : 0); }
		void operator() (int32_t i) const                        { writer.u32((uint32_t)i); }
		void operator() (uint64_t i) const                       { writer.u64(i); }
		void operator() (std::string const& str) const           { writer.string(str); }
		void operator() (std::vector<char> const& data) const    { writer.bytes(data.data(), data.size()); }
		void operator() (oak::date_t const& date) const          { writer.f64(date.value()); }

		void operator() (plist::array_t const& array) const
		{
			writer.varint(array.size());
			for(auto const& item : array)
				write(item);
		}

		void operator() (plist::dictionary_t const& dict) const
		{
			writer.varint(dict.size());
			for(auto const& pair : dict)
			{
				writer.string(pair.first);
				write(pair.second);
			}
		}

		void write (plist::any_t const& value) const
		{
			writer.u8(value.index());
			std::visit(*this, value);
		}
	};

	void write_any (oak::binary_writer_t& writer, plist::any_t const& value)
	{
		write_any_t{ writer }.write(value);
	}

	plist::any_t read_any (oak::binary_reader_t& reader, size_t depth = 0)
	{
		if(depth > 256)
			throw std::runtime_error("plist nested too deeply");

		switch(reader.u8())
		{
			case 0: return reader.u8() != 0;
			case 1: return (int32_t)reader.u32();
			case 2: return reader.u64();
			case 3: return reader.string();
			case 4: { std::string const data = reader.string(); return std::vector<char>(data.begin(), data.end()); }
			case 5: return oak::date_t(reader.f64());

			case 6:
			{
				plist::array_t res;
				for(size_t i = 0, n = reader.count(); i < n; ++i)
					res.push_back(read_any(reader, depth + 1));
				return res;
			}

			case 7:
			{
				plist::dictionary_t res;
				for(size_t i = 0, n = reader.count(); i < n; ++i)
				{
					std::string key = reader.string();
					res.emplace(std::move(key), read_any(reader, depth + 1));
				}
				return res;
			}
		}
		throw std::runtime_error("unknown plist type");
	}
}

namespace plist
{
	int32_t const cache_t::kPropertyCacheFormatVersion = 2;

	void cache_t::load (std::string const& path)
	{
		int32_t version;
		auto plist = plist::load(path);
		if(plist::get_key_path(plist, "version", version) && version == kPropertyCacheFormatVersion)
		{
			for(auto const& pair : plist)
			{
				if(plist::dictionary_t const* node = std::get_if<plist::dictionary_t>(&pair.second))
				{
					entry_t entry(pair.first);
					for(auto const& pair : *node)
					{
						if(pair.first == "content" && std::get_if<plist::dictionary_t>(&pair.second))
						{
							entry.set_type(entry_type_t::file);
							entry.set_content(std::get<plist::dictionary_t>(pair.second));
						}
						else if(pair.first == "link" && std::get_if<std::string>(&pair.second))
						{
							entry.set_type(entry_type_t::link);
							entry.set_link(std::get<std::string>(pair.second));
						}
						else if(pair.first == "missing" && std::get_if<bool>(&pair.second) && std::get<bool>(pair.second))
						{
							entry.set_type(entry_type_t::missing);
						}
						else if(pair.first == "entries" && std::get_if<plist::array_t>(&pair.second))
						{
							std::vector<std::string> v;
							for(auto path : std::get<plist::array_t>(pair.second))
								v.push_back(std::get<std::string>(path));

							entry.set_type(entry_type_t::directory);
							entry.set_entries(v);
						}
						else if(pair.first == "glob" && std::get_if<std::string>(&pair.second))
						{
							entry.set_glob_string(std::get<std::string>(pair.second));
						}
						else if(pair.first == "modified" && std::get_if<oak::date_t>(&pair.second))
						{
							entry.set_modified(std::get<oak::date_t>(pair.second).time_value());
						}
						else if(pair.first == "eventId" && std::get_if<uint64_t>(&pair.second))
						{
							entry.set_event_id(std::get<uint64_t>(pair.second));
						}
					}

					if(entry.type() != entry_type_t::unknown)
						_cache.emplace(pair.first, entry);
				}
			}
		}
	}

	void cache_t::load_binary (std::string const& path)
	{
		try {
			real_load(path);
		}
		catch(std::exception const& e) {
			os_log_error(OS_LOG_DEFAULT, "Exception thrown while loading ‘%{public}s’: %{public}s", path.c_str(), e.what());
			_cache.clear();
		}
	}

	void cache_t::real_load (std::string const& path)
	{
		std::string data;
		if(!oak::binary_reader_t::read_file(path, data))
			return;

		oak::binary_reader_t reader(std::move(data), kBinaryCacheMagic, kBinaryCacheFormatVersion);
		for(size_t i = 0, n = reader.count(); i < n; ++i)
		{
			entry_t entry(reader.string());
			switch(reader.u8())
			{
				case kBinaryEntryFile:
				{
					entry.set_type(entry_type_t::file);
					entry.set_modified(reader.u64());

					plist::dictionary_t plist;
					for(size_t j = 0, m = reader.count(); j < m; ++j)
					{
						std::string key = reader.string();
						plist.emplace(std::move(key), read_any(reader));
					}
					entry.set_content(plist);
				}
				break;

				case kBinaryEntryDirectory:
				{
					entry.set_type(entry_type_t::directory);
					entry.set_event_id(reader.u64());
					entry.set_glob_string(reader.string());

					std::vector<std::string> v;
					for(size_t j = 0, m = reader.count(); j < m; ++j)
						v.push_back(reader.string());
					entry.set_entries(v);
				}
				break;

				case kBinaryEntryLink:
				{
					entry.set_type(entry_type_t::link);
					entry.set_link(reader.string());
				}
				break;

				case kBinaryEntryMissing:
				{
					entry.set_type(entry_type_t::missing);
				}
				break;

				default:
					throw std::runtime_error("unknown entry type");
			}

			_cache.emplace(entry.path(), entry);
		}
	}

	void cache_t::save (std::string const& path) const
	{
		plist::dictionary_t plist;
		for(auto pair : _cache)
		{
			plist::dictionary_t node;

			plist::array_t entries;
			for(auto path : pair.second.entries())
				entries.push_back(path);

			if(pair.second.is_file())
			{
				node["content"] = pair.second.content();
				node["modified"] = oak::date_t(pair.second.modified());
			}
			else if(pair.second.is_link())
				node["link"] = pair.second.link();
			else if(pair.second.is_missing())
				node["missing"] = true;
			else if(pair.second.is_directory())
			{
				node["entries"] = entries;
				node["glob"] = pair.second.glob_string();
				if(pair.second.event_id())
					node["eventId"] = pair.second.event_id();
			}

			plist.emplace(pair.first, node);
		}
		plist["version"] = kPropertyCacheFormatVersion;
		plist::save(path, plist);
	}

	void cache_t::save_binary (std::string const& path) const
	{
		oak::binary_writer_t writer(kBinaryCacheMagic, kBinaryCacheFormatVersion);
		writer.varint(_cache.size());

		for(auto const& pair : _cache)
		{
			writer.string(pair.first);

			if(pair.second.is_file())
			{
				writer.u8(kBinaryEntryFile);
				writer.u64(pair.second.modified());

				auto const& plist = pair.second.content();
				writer.varint(plist.size());
				for(auto const& src : plist)
				{
					writer.string(src.first);
					write_any(writer, src.second);
				}
			}
			else if(pair.second.is_directory())
			{
				writer.u8(kBinaryEntryDirectory);
				writer.u64(pair.second.event_id());
				writer.string(pair.second.glob_string());

				auto const& v = pair.second.entries();
				writer.varint(v.size());
				for(auto const& item : v)
					writer.string(item);
			}
			else if(pair.second.is_link())
			{
				writer.u8(kBinaryEntryLink);
				writer.string(pair.second.link());
			}
			else
			{
				writer.u8(kBinaryEntryMissing);
			}
		}

		if(!writer.write_to_file(path))
			os_log_error(OS_LOG_DEFAULT, "Failed to write ‘%{public}s’: %{public}s", path.c_str(), strerror(errno));
	}

	uint64_t cache_t::event_id_for_path (std::string const& path) const
	{
		auto it = _cache.find(path);
		return it == _cache.end() ? 0 : it->second.event_id();
	}

	void cache_t::set_event_id_for_path (uint64_t eventId, std::string const& path)
	{
		auto it = _cache.find(path);
		if(it != _cache.end() && it->second.event_id() != eventId)
		{
			it->second.set_event_id(eventId);
			_dirty = true;
		}
	}

	plist::dictionary_t cache_t::content (std::string const& path)
	{
		auto it = _cache.find(path);
		if(it != _cache.end() && it->second.type() == entry_type_t::missing)
		{
			os_log_error(OS_LOG_DEFAULT, "Content requested for missing item: ‘%{public}s’", path.c_str());
			_cache.erase(it);
		}
		return resolved(path).content();
	}

	std::vector<std::string> cache_t::entries (std::string const& path, std::string const& globString)
	{
		entry_t& entry = resolved(path, globString);

		std::vector<std::string> res;
		for(auto path : entry.entries())
			res.emplace_back(path::join(entry.path(), path));
		return res;
	}

	bool cache_t::erase (std::string const& path)
	{
		auto first = _cache.find(path);
		if(first == _cache.end())
			return false;

		if(first->second.is_directory())
		{
			auto parent = _cache.find(path::parent(path));
			if(parent != _cache.end() && parent->second.is_directory())
			{
				std::vector<std::string> entries = parent->second.entries();
				auto name = std::find(entries.begin(), entries.end(), path::name(path));
				if(name != entries.end())
				{
					entries.erase(name);
					parent->second.set_entries(entries, parent->second.glob_string());
				}
			}
			_cache.erase(first, _cache.lower_bound(path + "0")); // path + "0" is the first non-descendent
		}
		else
		{
			_cache.erase(first);
		}

		_dirty = true;
		return true;
	}

	bool cache_t::reload (std::string const& path, bool recursive)
	{
		bool dirty = false;
		auto it = _cache.find(path);
		if(it == _cache.end())
			return path::is_absolute(path) && path != "/" ? reload(path::parent(path), recursive) : dirty;

		struct stat buf;
		if(lstat(path.c_str(), &buf) == 0)
		{
			if(S_ISDIR(buf.st_mode) && it->second.is_directory())
			{
				auto oldEntries = recursive ? std::vector<std::string>() : it->second.entries();
				update_entries(it->second, it->second.glob_string());
				auto newEntries = it->second.entries();
				dirty = oldEntries != newEntries;
				for(auto name : newEntries)
				{
					auto entryIter = _cache.find(path::join(path, name));
					if(entryIter != _cache.end() && (entryIter->second.is_file() || recursive))
						dirty = reload(path::join(path, name), recursive) || dirty;
				}
			}
			else if(!(it->second.is_file() && S_ISREG(buf.st_mode) && it->second.modified() == buf.st_mtimespec.tv_sec))
			{
				_cache.erase(it);
				dirty = true;
			}
		}
		else if(!it->second.is_missing())
		{
			_cache.erase(it);
			dirty = true;
		}

		_dirty = _dirty || dirty;
		return dirty;
	}

	bool cache_t::cleanup (std::vector<std::string> const& rootPaths)
	{
		std::set<std::string> allPaths, reachablePaths;
		std::transform(_cache.begin(), _cache.end(), std::inserter(allPaths, allPaths.end()), [](std::pair<std::string, entry_t> const& pair){ return pair.first; });
		for(auto path : rootPaths)
			copy_all(path, std::inserter(reachablePaths, reachablePaths.end()));

		std::vector<std::string> toRemove;
		std::set_difference(allPaths.begin(), allPaths.end(), reachablePaths.begin(), reachablePaths.end(), back_inserter(toRemove));

		for(auto path : toRemove)
			_cache.erase(path);
		_dirty = _dirty || !toRemove.empty();
		return !toRemove.empty();
	}

	// ============================
	// = Private Member Functions =
	// ============================

	cache_t::entry_t& cache_t::resolved (std::string const& path, std::string const& globString)
	{
		auto it = _cache.find(path);
		if(it == _cache.end())
		{
			entry_t entry(path);
			entry.set_type(entry_type_t::missing);

			struct stat buf;
			if(lstat(path.c_str(), &buf) == 0)
			{
				if(S_ISREG(buf.st_mode))
				{
					entry.set_type(entry_type_t::file);
				}
				else if(S_ISLNK(buf.st_mode))
				{
					entry.set_type(entry_type_t::link);
					entry.set_link(read_link(path));
				}
				else if(S_ISDIR(buf.st_mode))
				{
					entry.set_type(entry_type_t::directory);
				}
			}

			if(entry.is_file())
			{
				auto const content = plist::load(path);
				entry.set_content(_prune_dictionary ? _prune_dictionary(content) : content);
				entry.set_modified(buf.st_mtimespec.tv_sec);
			}
			else if(entry.is_directory())
			{
				update_entries(entry, globString);
			}

			it = _cache.emplace(path, entry).first;
			_dirty = true;
		}
		return it->second.is_link() ? resolved(it->second.resolved(), globString) : it->second;
	}

	void cache_t::update_entries (entry_t& entry, std::string const& globString)
	{
		std::vector<std::string> entries;
		for(auto dirEntry : path::entries(entry.path(), globString))
			entries.emplace_back(dirEntry->d_name);
		std::sort(entries.begin(), entries.end());
		entry.set_entries(entries, globString);
	}

} /* plist */
