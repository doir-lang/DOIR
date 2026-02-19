#define FP_OSTREAM_SUPPORT

#include <cstddef>
#include <filesystem>
#include <unordered_map>
#include <span>

#include <fp/hash.hpp>

#include "mio.hpp"

namespace doir {

	struct file_manager {
		static file_manager& singleton() {
			static file_manager m;
			return m;
		}

		std::unordered_map<std::filesystem::path, mio::mmap_source> mapped_files;

		mio::mmap_source& load_file(const std::filesystem::path& path) {
			if(mapped_files.contains(path)) return mapped_files[path];
			return mapped_files[path] = path.string();
		}

		fp::view<std::byte> get_file_bytes(std::filesystem::path path) {
			auto& mio = load_file(path);
			return {(std::byte*)mio.data(), mio.size()};
		}

		fp::string::view get_file_string(std::filesystem::path path) {
			auto& mio = load_file(path);
			return {mio.data(), mio.size()};
		}
	};

}
