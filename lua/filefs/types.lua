local Types = {}

Types.FileType = {
  FILE = "file",
  DIR = "dir",
  ROOT = "root",
}

Types.SeekWhence = {
  SET = "set",
  CUR = "cur",
  END = "end",
}

function Types.FileFsError(message)
  return setmetatable({ message = message }, {
    __tostring = function(self)
      return "FileFsError: " .. self.message
    end,
  })
end

return Types
