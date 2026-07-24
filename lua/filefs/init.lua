local FileSystem = require("filefs.filesystem")
local Types = require("filefs.types")

return {
  FileSystem = FileSystem,
  FileType = Types.FileType,
  SeekWhence = Types.SeekWhence,
  FileFsError = Types.FileFsError,
  mkfs = FileSystem.mkfs,
  new = function()
    return FileSystem.new()
  end,
}
