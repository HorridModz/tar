import zlib
import math
import struct
import os

var COMPRESS_AUTO = -1
var COMPRESS_NONE = 0
var COMPRESS_GZIP = 1
var COMPRESS_BZIP = 2

class TarCorruptedException < Exception {}
class TarIOException < Exception {}
class TarIllegalCompressionException < Exception {}

var _header_unpack = 'a100filename/a8perm/a8uid/a8gid/a12size/a12mtime/a8checksum/a1typeflag/a100link/a6magic/a2version/a32uname/a32gname/a8devmajor/a8devminor/a155prefix'

def octdec(v) {
  return to_number('0c' + to_string(v))
}

/**
 * Creates or extracts TAR archives with long pathnames (> 100 characters) 
 * support in POSIX ustar and GNU longlink formats.
 */
class Tar {
  var file
  var _comp_type = COMPRESS_AUTO
  var _comp_level = 9
  var _handle
  var _memory = bytes(0)
  var _closed = true
  var _can_write = false
  var _on_extracts = []
  var _on_adds = []

  /**
   * Set the compression level and type
   *
   * @param int level Compression level (0 to 9) - Default = 9
   * @param int type  Type of compression to use (use COMPRESS_* constants) - Default = COMPRESS_AUTO
   * @throws TarIllegalCompressionException
   */
  set_compression(level, type) {
    if !level level = 9
    if !type type = COMPRESS_AUTO

    self._compression_check(type)
    if level < -1 or level >  9
      die TarIllegalCompressionException('compression level should be between -1 and 9')
    self._comp_level = level
    self._comp_type = type

    if level == 0 self._comp_type = COMPRESS_NONE
    if type == COMPRESS_NONE self._comp_level = 0
  }

  /**
   * Open an existing Tar file for reading
   *
   * @param string file
   * @throws TarIOException
   * @throws TarIllegalCompressionException
   */
  open(file) {
    self._file = file

    if self._comp_type == COMPRESS_AUTO
      self.set_compression(self._comp_level, self.file_type(file))

    if self._comp_type == COMPRESS_GZIP
      self._handle = zlib.gzopen(self._file, 'rb')
    else if self._comp_type == COMPRESS_BZIP
      die TarIllegalCompressionException('bzip2 is not supported')
    else self._handle = file(self._file, 'rb')

    if !self._handle
      die TarIOException('could not open file "${self._file}" for reading')

    self._closed = false
  }

  /**
   * Read the contents of a Tar archive
   *
   * This function lists the files stored in the Tar, and returns an indexed array of FileInfo objects
   *
   * The Tar is closed afer reading the contents, because rewinding is not possible in bzip2 streams.
   * Reopen the file with open() again if you want to do additional operations
   *
   * @return List<Dictionary>
   */
  contents() {
    if self._closed or !self._file
      die TarIOException('cannot read from a closed archive')

    var result = [], read

    while read = self._read_bytes(512) {
      var header = self._parse_header(read)
      if !header or !is_dict(header) continue
      
      self._skip_bytes(math.ceil(header.size / 512) * 512)
      result.append(header)
    }

    self.close()

    return result
  }

  /**
   * Extract an existing Tar archive
   *
   * The strip parameter allows you to strip a certain number of path components from the filenames
   * found in the Tar file, similar to the --strip-components feature of GNU tar. This is triggered when
   * an integer is passed as strip.
   * Alternatively a fixed string prefix may be passed in strip. If the filename matches this prefix,
   * the prefix will be stripped. It is recommended to give prefixes with a trailing slash.
   *
   * By default this will extract all files found in the Tar. You can restrict the output using the include
   * and exclude parameter. Both expect a full regular expression (including delimiters and modifiers). If
   * include is set, only files that match this expression will be extracted. Files that match the exclude
   * expression will never be extracted. Both parameters can be used in combination. Expressions are matched against
   * stripped filenames as described above.
   *
   * The Tar is closed afterwards. Reopen the file with open() again if you want to do additional operations
   *
   * @param string     outdir  the target directory for extracting
   * @param int|string strip   either the number of path components or a fixed prefix to strip
   * @param string     exclude a regular expression of files to exclude
   * @param string     include a regular expression of files to include
   * @throws TarIOException
   * @return list
   */
  extract(outdir, strip, exclude, include) {
    if !is_string(outdir)
      die Exception('output directory required as first argument')

    outdir = outdir.rtrim('/')
    if !os.dir_exists(outdir) {
      if !os.create_dir(outdir)
        die TarIOException('could not create directory "${outdir}"')
    }

    var extracted = [], data

    while data = self._read_bytes(512) {
      # read the file header
      var header = self._parse_header(data)
      if !header or !is_dict(header) continue

      var is_dir = header.typeflag > 0
      if strip {
        header.filename == self._strip(header.filename, is_dir, strip)
      }

      # skip unwanted files
      if header.filename.length() == 0 continue
      if exclude and header.filename.match(exclude) continue
      if include and !header.filename.match(include) continue

      # create output directory
      var output = os.join_paths(outdir, header.filename)
      var directory = is_dir ? output : os.dir_name(output)
      if !os.dir_exists(directory)
        os.create_dir(directory)

      # extract data
      if !is_dir {
        var fp = file(output, 'wb')

        var size = header.size // 512
        iter var i = 0; i < size; i++ {
          fp.puts(self._read_bytes(512))
        }
        if header.size % 512 != 0 {
          var rem = header.size % 512
          fp.puts(self._read_bytes(512)[,rem])
        }

        # set times
        fp.chmod(header.perm)
        fp.set_times(-1, header.mtime)

        fp.close()
      } else {
        self._skip_bytes(math.ceil(header.size / 512) * 512)  # the size is usually 0 for directories
      }

      # handle callbacks
      if self._on_extracts {
        for fn in self._on_extracts {
          fn(header)
        }
      }

      extracted.append(header)
    }

    self.close()
    return extracted
  }

  /**
   * Create a new Tar file
   *
   * If file is empty, the Tar file will be created in memory
   *
   * @param string file
   */
  create(file) {
    self._file = file
    self._handle = nil
    self._memory = bytes(0)

    if self._file {
      if self._comp_type == COMPRESS_AUTO
        self.set_compression(self._comp_level, self.file_type(file))

      if self._comp_type == COMPRESS_GZIP
        self._handle = zlib.gzopen(self._file, 'wb')
      else if self._comp_type == COMPRESS_BZIP
        die TarIllegalCompressionException('bzip2 is not supported')
      else self._handle = file(self._file, 'wb')

      if !self._handle
        die TarIOException('could not open file "${self._file}" for writing')
    }

    self._can_write = true
    self._closed = false
  }

  /**
   * Add a file to the current Tar using an existing file in the filesystem
   *
   * @param string path         path to the original file
   * @param string|dict header  either the name to use in Tar (string) or a dictionary oject with all meta data, empty to take from original
   * @throws TarIOException
   */
  add_file(path, header) {
    if self._closed
      die TarIOException('archive has been closed and files can no longer be added')

    if header == nil or is_string(header) {
      header = self._header_from_path(path, header)
    }

    self._write_file_header(header)
    var is_dir = header.typeflag == 5

    if !is_dir and header.size > 0 {
      var fp = file(path, 'rb')
      var read = 0, total = fp.stats().size

      while read < total {
        var data = fp.gets(512)
        read += data.length()

        if !data break
        self._write_bytes(struct.pack('a512', data.to_string().ascii()))
      }
      fp.close()

      if read != total {
        self.close()
        die TarCorruptedException('The size of ${file} changed while reading, archive corrupted. read ${read} expected ${total}')
      }
    }

    # handle callbacks
    if self._on_adds {
      for fn in self._on_adds {
        fn(header)
      }
    }
  }

  /**
   * Add a file to the current Tar using the given data as content.
   * If the header is set to nil or empty string, a file called `Untitled-{CURRENT_TIMESTAMP}` will be created.
   *
   * @param bytes data     binary content of the file to add
   * @param string|dict header either the name to us in Tar (string) or a dictionary oject with all meta data
   * @throws TarIOException
   */
  add_data(data, header) {
    if self._closed
      die TarIOException('archive has been closed and files can no longer be added')

    if header == nil or is_string(header) {
      header = {
        filename: header or 'Untitled-${time()}',
        perm: 0c664,
        uid: 0,
        gid: 0,
        size: data.length(),
        mtime: 0,
        typeflag: 0,
        link: 0,
        uname: '',
        gname: '',
      }
    }

    self._write_file_header(header)

    iter var i = 0; i < data.length(); i += 512 {
      self._write_bytes(struct.pack('a512', data[i,i+512].to_string().ascii()))
    }

    # handle callbacks
    if self._on_adds {
      for fn in self._on_adds {
        fn(header)
      }
    }
  }

  /**
   * Add the closing footer to the archive if in write mode, close all file handles
   *
   * After a call to this function no more data can be added to the archive, for
   * read access no reading is allowed anymore
   *
   * "Physically, an archive consists of a series of file entries terminated by an end-of-archive entry, which
   * consists of two 512 blocks of zero bytes"
   *
   * @link http://www.gnu.org/software/tar/manual/html_chapter/tar_8.html#SEC134
   * @throws TarIOException
   */
  close() {
    if self._closed return

    if self._can_write {
      self._write_bytes(struct.pack('a512', ''))
      self._write_bytes(struct.pack('a512', ''))
    }

    if self._file {
      if self._comp_type == COMPRESS_GZIP
        self._handle.close()
      else if self._comp_type == COMPRESS_BZIP
        die TarIllegalCompressionException('bzip2 is not supported')
      else self._handle.close()

      self._file = nil
      self._handle = nil
    }

    self._can_write = false
    self._closed = true
  }

  /**
   * Returns the created in-memory Tar data
   *
   * This implicitly calls close() on the Tar.
   * 
   * @throws TarIOException
   * @throws TarIllegalCompressionException
   * @returns bytes
   */
  get_archive() {
    self.close()

    if self._comp_type == COMPRESS_AUTO
      self._comp_type = COMPRESS_NONE

    if self._comp_type == COMPRESS_GZIP
      return zlib.compress(self._memory, self._comp_level, zlib.DEFAULT_STRATEGY, zlib.MAX_WBITS | 16)
    else if self._comp_type == COMPRESS_BZIP
      die TarIllegalCompressionException('bzip2 is not supported')
    return self._memory
  }

  /**
   * Save the created in-memory Tar data
   *
   * Note: It is more memory effective to specify the filename in the create() function and
   * let the library work on the new file directly.
   *
   * @param string path
   */
  save(path) {
    if self._comp_type == COMPRESS_AUTO
      self.set_compression(self._comp_level, self.file_type(path))
    return file(path, 'wb').write(self._memory)
  }

  /**
   * Adds the specified `directory` recursively to the archive and set's it path in the archive to `dir`.
   * 
   * @param string directory
   * @param string file_blacklist if not empty, this function will ignore every file with a matching path.
   * @param list ext_blacklist if not empty, this function will ignore every file with a matching extension.
   * @throws TarIOException|Exception
   */
  add_directory(directory, file_blacklist, ext_blacklist) {
    if !is_string(directory)
      die Exception('expected string in argument 1 (directory)')
    if file_blacklist != nil and !is_list(file_blacklist)
      die Exception('expected list in argument 2 (file_blacklist)')
    if ext_blacklist != nil and !is_list(ext_blacklist)
      die Exception('expected list in argument 3 (ext_blacklist)')

    directory = directory.replace('/\\\\/', '/')

    if !os.dir_exists(directory)
      die TarIOException('directory ${directory} not found')

    if !file_blacklist file_blacklist = []
    if !ext_blacklist ext_blacklist = []

		self._add_files(directory, '', file_blacklist, ext_blacklist)
	}

  _add_files(path, dir, file_blacklist, ext_blacklist) {
		var gpath = os.join_paths(path, dir)
    
		if os.dir_exists(gpath) {
			var sources = os.read_dir(gpath)
      for source in sources {

        # check ext blacklist here...
        for ext in ext_blacklist {
          if source.ends_with('.${ext}')
          return
        }

        if source != '.' and source != '..' {
          var npath = os.join_paths(gpath, source)

          var cur_dir = os.cwd()
          if npath.starts_with(cur_dir) {
            npath = npath[cur_dir.length(),]

            # Just in case...
            if npath.starts_with('/')
              npath = npath[1,]
          }

          # check file blacklist here...
          if file_blacklist.contains(npath)
            return

          if os.is_dir(npath) {
            self._add_files(gpath, source, file_blacklist, ext_blacklist)
          } else {
            self.add_file(npath)
          }
        }
      }
		}
	}

  _compression_check(type) {
    if type == COMPRESS_BZIP
      die TarIllegalCompressionException('bzip2 is not supported')
  }

  /**
   * Guesses the wanted compression from the given file
   *
   * Uses magic bytes for existing files, the file extension otherwise
   *
   * You don't need to call this yourself. It's used when you pass `COMPRESS_AUTO` somewhere
   *
   * @param string file
   * @return int (one of COMPRESS_BZIP, COMPRESS_GZIP or COMPRESS_NONE)
   */
  file_type(f) {
    var ff = file(f, 'rb')

    if ff.exists() {
      var stat = ff.stats()
      if stat.is_readable and stat.size > 5 {
        ff.open()
        var magic = ff.gets(5)
        ff.close()

        if magic.to_string().starts_with('\x42\x5a') return COMPRESS_BZIP
        if magic.to_string().starts_with('\x1f\x86') return COMPRESS_GZIP
      }
    }

    # else rely on filename
    if f.ends_with('.gz') or f.ends_with('.tgz') return COMPRESS_GZIP
    else if f.ends_with('.bz2') or f.ends_with('.tbz') return COMPRESS_BZIP

    return COMPRESS_NONE
  }

  _read_bytes(length) {
    if self._comp_type == COMPRESS_GZIP
      return self._handle.read(length)
    else if self._comp_type == COMPRESS_BZIP
      die TarIllegalCompressionException('bzip2 is not supported')
    else return self._handle.gets(length)
  }

  _write_bytes(data) {
    var written
    if !self._file {
      self._memory += data
      written = data.length()
    } else if self._comp_type == COMPRESS_GZIP
      written = self._handle.read(length)
    else if self._comp_type == COMPRESS_BZIP
      die TarIllegalCompressionException('bzip2 is not supported')
    else written = self._handle.gets(length)

    if !written die TarIOException('failed to write to archive stream')
    return written
  }

  _skip_bytes(bytes) {
    if self._comp_type == COMPRESS_GZIP
      self._handle.seek(bytes, zlib.SEEK_CUR)
    else if self._comp_type == COMPRESS_BZIP
      die TarIllegalCompressionException('bzip2 is not supported')
    else self._handle.seek(bytes, zlib.SEEK_CUR)
  }

  _parse_header(block) {
    if !block or block.length() != 512
      die TarCorruptedException('unexpected length of header')

    block = block.to_string().ascii()
    if !block.trim() return false

    var chks = 0
    iter var i = 0; i < 148; i++ {
      chks += ord(block[i])
    }
    chks += 256
    iter var i = 156; i < 512; i++ {
      chks += ord(block[i])
    }
    
    var header = struct.unpack(_header_unpack, block)
    if !header die TarCorruptedException('failed to parse header')
    
    var result = {
      checksum: octdec(header.checksum.trim())
    }

    # if result.checksum != chks
    #   die TarCorruptedException('header does not match its checksum')

    # if result.checksum == chks {
    if header.checksum.match('/^\d+/') {
      result.filename = header.filename.trim()
      result.perm = octdec(header.perm.trim())
      result.uid = octdec(header.uid.trim())
      result.gid = octdec(header.gid.trim())
      result.size = octdec(header.size.trim())
      result.mtime = octdec(header.mtime.trim())
      result.typeflag = to_number(header.typeflag)
      result.link = header.link.trim()
      result.uname = header.uname.trim()
      result.gname = header.gname.trim()

      # handle ustar Posix compliant path prefixes
      if header.prefix.trim() {
        result.filename = header.prefix.trim() + '/' + result.filename
      }

      # handle Long-link entries from GNU Tar
      if result.typeflag == 'L' {
        # the following data block(s) is the filename
        var filename = self._read_bytes(math.ceil(result.size / 512) * 512)
        # next block is the real header
        var block = self._read_bytes(512)
        result = self._parse_header(block)
        # overwrite the filename
        result.filename = filename
      }

      return result
    }
    
    return false
  }

  _strip(filename, is_dir, strip) {
    if is_number(strip) {
      # if strip is an integer we strip this many path components
      var parts = filename.split('/'), 
          base = is_dir ? '' : parts.pop()

      filename = '/'.join(parts[strip,])
    } else {
      if filename.starts_with(strip)
        filename = filename[strip.length(),]
    }

    return filename
  }

  _header_from_path(path, _as) {
    var fp = file(path)
    if !fp.exists()
      die Exception('file "${path}" does not exist')

    var stat = fp.stats()
    return {
      filename: _as ? _as : fp.path(),
      perm: stat.mode or 0c664,
      uid: stat.uid or 0,
      gid: stat.gid or 0,
      size: stat.size or 0,
      mtime: stat.mtime or 0,
      typeflag: os.dir_exists(path) ? 5 : 0,
      link: stat.nlink or 0,
      uname: '',
      gname: '',
    }
  }

  _write_file_header(header) {
    self._write_raw_file_header(
      header.filename,
      header.uid,
      header.gid,
      header.perm,
      header.size,
      header.mtime,
      header.typeflag
    )
  }

  _write_raw_file_header(name, uid, gid, perm, size, mtime, typeflag) {
    var prefix = ''
    if name.length() > 100 {
      var file = os.base_name(name)
      var dir = os.dir_name(name)

      if file.length() > 100 or dir.length() > 155 {
        # we're still too large. Let's use GNU longlink
        self._write_raw_file_header('././@LongLink', 0, 0, 0, name.length(), 0, 'L')
        iter var i = 0; i < name.length(); i += 512 {
          self._write_bytes(struct.pack('a512', name[s,s+512]))
        }
        name = name[,100] # cut off name
      } else {
        # we're fine when splitting, use POSIX ustar
        prefix = dir
        name = file
      }
    }

    # values needed in octal
    uid = to_string(oct(uid)).lpad(6) + ' '
    gid = to_string(oct(gid)).lpad(6) + ' '
    perm = to_string(oct(perm)).lpad(6) + ' '
    size = to_string(oct(size)).lpad(11) + ' '
    mtime = to_string(oct(mtime)).lpad(11)

    var first_data = struct.pack('a100a8a8a8a12A12', name, perm, uid, gid, size, mtime)
    var last_data = struct.pack('a1a100a6a2a32a32a8a8a155a12', typeflag, '', 'ustar', '', '', '', '', '', prefix, '')
    
    var chks = 0
    iter var i = 0; i < 148; i++ {
      chks += first_data[i]
    }
    chks += 256
    iter var i = 156; i < 512; i++ {
      chks += last_data[i - 156]
    }

    self._write_bytes(first_data)

    chks = struct.pack('a8', to_string(oct(chks)).lpad(6) + ' ')
    self._write_bytes(chks + last_data)
  }
}

/**
 * Create a new TAR ball from the file or directory in the given path and saves it to the destination
 *  path or ${NAME_OF_FILE}.tar.gz in the current directory if the destination is not given.
 * 
 * @param string path the file or directory that will be compressed.
 * @param string destination the destination of the compressed TAR ball.
 */
def compress(path, destination) {
  if !destination destination = os.base_name(path) + '.tar.gz'

  var tar = Tar()
  var is_dir = os.dir_exists(path)
  var is_file = file(path).exists()

  if !is_dir and !is_file
    die TarIOException('cannnot find path "${path}"')

  tar.create()
  if is_dir tar.add_directory(path)
  else tar.add_file(path)
  tar.save(destination)
}

/**
 * Extracts a TAR file to the given destination or to the same directory as the source file with the 
 * same name as the TAR file (without the last extension) if destination is not given.
 * 
 * @param string file the file to be extracted
 * @param string destination the path to extract to (Optional).
 * @return list of extracted items
 */
def extract(file, destination) {
  if !destination
    destination = '.'.join(file.split('.')[,-1])
  var tar = Tar()
  tar.open(file)
  return tar.extract(destination)
}
