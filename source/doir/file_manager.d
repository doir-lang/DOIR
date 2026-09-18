/// The process-wide cache of loaded source files. Ported from
/// file_manager.hpp.
///
/// The C++ version memory-mapped each file with mio. `-betterC` has no
/// portable mmap wrapper to lean on, so this maps files directly through the
/// platform API (`mmap` on Posix, `CreateFileMapping`/`MapViewOfFile` on
/// Windows) and falls back to slurping the file into an owned libfp buffer
/// wherever mapping is unavailable or fails. The observable contract is the
/// same one the rest of the compiler relies on: a slice handed out here stays
/// valid (and at a fixed address) for the rest of the run, because interned
/// strings and source locations point into it.
///
/// The one thing mapping buys that reading does not cost us: a source file
/// truncated out from under a running compile faults on access rather than
/// yielding stale bytes. That is the same bargain the C++ version made.
///
/// Compile with `-version=DoirNoMmap` to force the read-into-memory path.
module doir.file_manager;

import core.stdc.stdio : FILE, SEEK_END, SEEK_SET, fclose, fopen, fread, fseek, ftell;
import core.stdc.string : strlen;

static import fp.dynarray;
import fp.dynarray : daLength = length;
import fp.pointer : allocFunction;
import fp.string : makeDynamicSlice, strFree = free, strLength = length, strSlice = slice;

@nogc nothrow:


/// How a cached file's bytes were acquired, and therefore how they are released.
private enum Backing : ubyte {
	none,   /// Empty file; `contents` is null and there is nothing to release.
	heap,   /// `allocFunction` buffer read through stdio.
	mapped, /// A read-only view of the file mapped into the address space.
}

private struct LoadedFile {
	char* path;     // owned libfp string
	char* contents; // null for an empty file
	size_t size;
	Backing backing;
}

private __gshared LoadedFile* loadedFiles = null;

/// Releases every cached file. Only safe once nothing still holds a slice.
void freeFileManager() @trusted {
	if (loadedFiles is null) return;
	foreach (i; 0 .. daLength(loadedFiles)) {
		strFree(loadedFiles[i].path);
		final switch (loadedFiles[i].backing) {
			case Backing.none: break;
			case Backing.heap: allocFunction(loadedFiles[i].contents, 0); break;
			case Backing.mapped: unmapFile(loadedFiles[i].contents, loadedFiles[i].size); break;
		}
	}
	fp.dynarray.free(loadedFiles);
	loadedFiles = null;
}

private LoadedFile* findLoaded(const(char)[] path) @trusted {
	foreach (i; 0 .. daLength(loadedFiles))
		if (strSlice(loadedFiles[i].path) == path)
			return &loadedFiles[i];
	return null;
}

/// Loads `path` (or returns the already-loaded copy). `ok` is false when the
/// file could not be opened - the C++ version threw `std::system_error` here,
/// which the SourceInfo handler caught to report `FileDoesNotExist`.
const(char)[] getFileString(const(char)[] path, out bool ok) @trusted {
	if (auto cached = findLoaded(path)) {
		ok = true;
		return cached.contents is null ? "" : cached.contents[0 .. cached.size];
	}

	char* zPath = makeDynamicSlice(path);

	LoadedFile loaded = LoadedFile(zPath, null, 0, Backing.none);
	if (!mapFile(zPath, loaded.contents, loaded.size, loaded.backing)
		&& !readFile(zPath, loaded.contents, loaded.size, loaded.backing)) {
		strFree(zPath);
		ok = false;
		return null;
	}

	fp.dynarray.pushBack(loadedFiles, loaded);
	ok = true;
	return loaded.contents is null ? "" : loaded.contents[0 .. loaded.size];
}

/// Ditto, as raw bytes.
const(ubyte)[] getFileBytes(const(char)[] path, out bool ok) @trusted {
	return cast(const(ubyte)[]) getFileString(path, ok);
}

/// True if `path` can be opened for reading.
bool fileExists(const(char)[] path) @trusted {
	bool ok;
	getFileString(path, ok);
	return ok;
}


// ---------------------------------------------------------------------------
// Reading fallback
// ---------------------------------------------------------------------------

/// Slurps the whole file through stdio. False when it cannot be opened or the
/// buffer cannot be allocated.
private bool readFile(const(char)* zPath, out char* contents, out size_t size, out Backing backing) @trusted {
	FILE* f = fopen(zPath, "rb");
	if (f is null) return false;
	scope(exit) fclose(f);

	fseek(f, 0, SEEK_END);
	immutable long told = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (told <= 0) {
		// Empty, or a stream with no queryable length (a pipe or a device);
		// either way there is nothing we can size a buffer from.
		backing = Backing.none;
		return true;
	}

	immutable size_t wanted = cast(size_t) told;
	char* buffer = cast(char*) allocFunction(null, wanted);
	if (buffer is null) return false;

	// A short read is a text-mode translation or a racing truncation; keep
	// what we got rather than failing the whole load.
	immutable size_t read = fread(buffer, 1, wanted, f);
	if (read == 0) {
		allocFunction(buffer, 0);
		backing = Backing.none;
		return true;
	}

	contents = buffer;
	size = read;
	backing = Backing.heap;
	return true;
}


// ---------------------------------------------------------------------------
// Memory mapping
// ---------------------------------------------------------------------------

version (DoirNoMmap) {
	private enum haveMmap = false;
} else version (Posix) {
	private enum haveMmap = true;
} else version (Windows) {
	private enum haveMmap = true;
} else {
	private enum haveMmap = false;
}

version (Windows) {
	private alias HANDLE = void*;
	private enum HANDLE invalidHandle = cast(HANDLE) cast(ptrdiff_t) -1;

	private extern(Windows) @nogc nothrow {
		HANDLE CreateFileA(const(char)* fileName, uint access, uint shareMode, void* security,
			uint creationDisposition, uint flagsAndAttributes, HANDLE templateFile);
		int GetFileSizeEx(HANDLE file, long* size);
		HANDLE CreateFileMappingA(HANDLE file, void* attributes, uint protect,
			uint maximumSizeHigh, uint maximumSizeLow, const(char)* name);
		void* MapViewOfFile(HANDLE mapping, uint desiredAccess,
			uint offsetHigh, uint offsetLow, size_t bytesToMap);
		int UnmapViewOfFile(const(void)* baseAddress);
		int CloseHandle(HANDLE object);
	}
}

/// Maps `zPath` read-only. False when mapping is unsupported, or when the
/// platform refused it, in which case the caller falls back to `readFile`.
private bool mapFile(const(char)* zPath, out char* contents, out size_t size, out Backing backing) @trusted {
	static if (!haveMmap) return false;
	else version (Posix) {
		import core.sys.posix.fcntl : O_RDONLY, open;
		import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, PROT_READ, mmap;
		import core.sys.posix.unistd : close, lseek;

		immutable fd = open(zPath, O_RDONLY);
		if (fd < 0) return false;
		scope(exit) close(fd);

		// lseek rather than fstat: it needs no per-platform `stat` layout and
		// tells us just as well whether the file has a length we can map.
		immutable end = lseek(fd, 0, SEEK_END);
		if (end < 0 || end > size_t.max) return false;
		if (end == 0) {
			backing = Backing.none; // Empty file; mmap rejects a zero length.
			return true;
		}

		immutable size_t length = cast(size_t) end;
		void* view = mmap(null, length, PROT_READ, MAP_PRIVATE, fd, 0);
		if (view is MAP_FAILED) return false;

		contents = cast(char*) view;
		size = length;
		backing = Backing.mapped;
		return true;
	} else version (Windows) {
		enum uint genericRead = 0x8000_0000;
		enum uint fileShareRead = 0x0000_0001;
		enum uint openExisting = 3;
		enum uint fileAttributeNormal = 0x0000_0080;
		enum uint pageReadonly = 0x0000_0002;
		enum uint fileMapRead = 0x0000_0004;

		HANDLE file = CreateFileA(zPath, genericRead, fileShareRead, null,
			openExisting, fileAttributeNormal, null);
		if (file is invalidHandle) return false;
		scope(exit) CloseHandle(file);

		long end;
		if (!GetFileSizeEx(file, &end) || end < 0 || end > size_t.max) return false;
		if (end == 0) {
			backing = Backing.none; // Empty file; CreateFileMapping rejects it.
			return true;
		}

		HANDLE mapping = CreateFileMappingA(file, null, pageReadonly, 0, 0, null);
		if (mapping is null) return false;
		scope(exit) CloseHandle(mapping); // The view keeps the mapping alive.

		void* view = MapViewOfFile(mapping, fileMapRead, 0, 0, 0);
		if (view is null) return false;

		contents = cast(char*) view;
		size = cast(size_t) end;
		backing = Backing.mapped;
		return true;
	}
}

/// Releases a view handed out by `mapFile`.
private void unmapFile(char* contents, size_t size) @trusted {
	static if (!haveMmap) assert(0, "nothing here was mapped");
	else version (Posix) {
		import core.sys.posix.sys.mman : munmap;
		munmap(contents, size);
	} else version (Windows) {
		UnmapViewOfFile(contents);
	}
}


// ---------------------------------------------------------------------------
// Path canonicalisation (the C++ `std::filesystem::canonical(absolute(p))`)
// ---------------------------------------------------------------------------

version (Posix) {
	private extern(C) char* realpath(const(char)* path, char* resolved) @nogc nothrow;
} else version (Windows) {
	private extern(C) char* _fullpath(char* absPath, const(char)* relPath, size_t maxLength) @nogc nothrow;
}

/// Resolves `path` to an absolute, symlink-free path. Returns a libfp string
/// the caller frees, or null when the path cannot be resolved (which the C++
/// version surfaced as a thrown `filesystem_error`).
char* canonicalPath(const(char)[] path) @trusted {
	char* zPath = makeDynamicSlice(path);
	scope(exit) strFree(zPath);

	enum size_t maxPath = 4096;
	char[maxPath] buffer;

	version (Posix) {
		if (realpath(zPath, buffer.ptr) is null) return null;
	} else version (Windows) {
		if (_fullpath(buffer.ptr, zPath, maxPath) is null) return null;
	} else {
		return makeDynamicSlice(path);
	}

	return makeDynamicSlice(buffer[0 .. strlen(buffer.ptr)]);
}
