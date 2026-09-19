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
import std.typecons : Nullable;

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

/// Loads `path` (or returns the already-loaded copy), or null when the file
/// could not be opened - the C++ version threw `std::system_error` here, which
/// the SourceInfo handler caught to report `FileDoesNotExist`. An empty file
/// reads back as a non-null empty slice, which is why this is a `Nullable`
/// rather than a plain slice whose own null state would conflate the two.
Nullable!(const(char)[]) getFileString(const(char)[] path) @trusted {
	alias Result = Nullable!(const(char)[]);

	if (auto cached = findLoaded(path))
		return Result(cached.contents is null ? "" : cached.contents[0 .. cached.size]);

	char* zPath = makeDynamicSlice(path);

	LoadedFile loaded = LoadedFile(zPath, null, 0, Backing.none);
	if (!mapFile(zPath, loaded.contents, loaded.size, loaded.backing)
		&& !readFile(zPath, loaded.contents, loaded.size, loaded.backing)) {
		strFree(zPath);
		return Result.init;
	}

	fp.dynarray.pushBack(loadedFiles, loaded);
	return Result(loaded.contents is null ? "" : loaded.contents[0 .. loaded.size]);
}

/// Ditto, as raw bytes.
Nullable!(const(ubyte)[]) getFileBytes(const(char)[] path) @trusted {
	auto contents = getFileString(path);
	if (contents.isNull) return Nullable!(const(ubyte)[]).init;
	return Nullable!(const(ubyte)[])(cast(const(ubyte)[]) contents.get);
}

/// True if `path` can be opened for reading.
bool fileExists(const(char)[] path) @trusted {
	return !getFileString(path).isNull;
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
	// what we got rather than failing the whole load. A read of *nothing*
	// leaves an owned but empty buffer, which reads back as empty text the
	// same way an empty file does.
	immutable size_t read = fread(buffer, 1, wanted, f);

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


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The cache is process-wide and hands out slices that have to stay valid for
// the rest of the run, so these only ever add to it - except the one that
// tears it down, which is deliberately the last word on it.

version (unittest) {
	import core.stdc.stdio : fputs, fwrite, remove;

	/// Writes `contents` to `path`, replacing whatever was there.
	private bool writeTestFile(const(char)* path, const(char)[] contents) @trusted {
		FILE* f = fopen(path, "wb");
		if (f is null) return false;
		if (contents.length) fwrite(contents.ptr, 1, contents.length, f);
		fclose(f);
		return true;
	}
}

unittest { // a file that exists loads, caches, and comes back identical twice
	auto first = getFileString("README.md");
	assert(!first.isNull);
	assert(first.get.length > 0);

	// The second call is served from the cache, and must be the *same* bytes:
	// interned strings and source locations point into them.
	auto second = getFileString("README.md");
	assert(!second.isNull);
	assert(second.get.ptr is first.get.ptr);
	assert(second.get.length == first.get.length);

	// ...and the two convenience wrappers over it.
	auto bytes = getFileBytes("README.md");
	assert(!bytes.isNull);
	assert(bytes.get.length == first.get.length);
	assert(fileExists("README.md"));
}

unittest { // a file that does not exist reports failure rather than empty text
	assert(getFileString("/nonexistent/definitely_not_here.doir").isNull);
	assert(getFileBytes("/nonexistent/definitely_not_here.doir").isNull);
	assert(!fileExists("/nonexistent/definitely_not_here.doir"));
}

unittest { // an empty file loads as empty text, not as a failure
	enum path = "doir_empty_test_file.tmp";
	assert(writeTestFile(path, ""));
	scope(exit) remove(path);

	// The distinction the `Nullable` exists for: present, but zero bytes.
	auto contents = getFileString(path);
	assert(!contents.isNull);
	assert(contents.get.length == 0);
}

unittest {
	// `readFile` is the fallback for platforms (or builds) where mapping is
	// unavailable, so on a platform that does map it is never reached through
	// `getFileString`. It has the same contract either way.
	enum path = "doir_read_test_file.tmp";
	assert(writeTestFile(path, "hello"));
	scope(exit) remove(path);

	char* zPath = makeDynamicSlice(path);
	scope(exit) strFree(zPath);

	char* contents;
	size_t size;
	Backing backing;
	assert(readFile(zPath, contents, size, backing));
	assert(backing == Backing.heap);
	assert(contents[0 .. size] == "hello");
	allocFunction(contents, 0);

	// An empty file has no length to size a buffer from.
	enum emptyPath = "doir_read_empty_test_file.tmp";
	assert(writeTestFile(emptyPath, ""));
	scope(exit) remove(emptyPath);

	char* emptyZ = makeDynamicSlice(emptyPath);
	scope(exit) strFree(emptyZ);
	char* emptyContents;
	size_t emptySize;
	Backing emptyBacking;
	assert(readFile(emptyZ, emptyContents, emptySize, emptyBacking));
	assert(emptyBacking == Backing.none);
	assert(emptyContents is null);

	// One that cannot be opened at all.
	char* missingZ = makeDynamicSlice("/nonexistent/definitely_not_here.doir");
	scope(exit) strFree(missingZ);
	char* missingContents;
	size_t missingSize;
	Backing missingBacking;
	assert(!readFile(missingZ, missingContents, missingSize, missingBacking));
}

unittest { // canonicalPath resolves a relative path, and rejects a missing one
	auto resolved = canonicalPath("README.md");
	scope(exit) strFree(resolved);
	assert(resolved !is null);
	assert(strLength(resolved) > "README.md".length); // absolute, so longer
	assert(strSlice(resolved)[0] == '/' || strSlice(resolved)[1] == ':');

	assert(canonicalPath("/nonexistent/definitely_not_here.doir") is null);
}

unittest {
	// Tearing the cache down releases each backing kind. This runs last on
	// purpose: every slice handed out before it is dangling afterwards, which
	// is exactly why the rest of the compiler never calls it.
	enum path = "doir_teardown_test_file.tmp";
	assert(writeTestFile(path, "mapped contents"));
	scope(exit) remove(path);

	auto mapped = getFileString(path);
	assert(!mapped.isNull);
	assert(mapped.get.length == "mapped contents".length);

	// An entry whose bytes came from the reading fallback, so the `heap` arm
	// is released too (nothing on a mapping platform produces one otherwise).
	char* heapPath = makeDynamicSlice("doir_teardown_heap.tmp");
	LoadedFile heapEntry = LoadedFile(heapPath, cast(char*) allocFunction(null, 4), 4, Backing.heap);
	fp.dynarray.pushBack(loadedFiles, heapEntry);

	freeFileManager();
	assert(loadedFiles is null);
	freeFileManager(); // idempotent

	// The cache refills from scratch afterwards.
	assert(fileExists("README.md"));
}
