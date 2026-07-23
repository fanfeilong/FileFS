use std::fmt;
use std::io;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Io(io::ErrorKind),
    NotMounted,
    NotFound,
    AlreadyExists,
    NameTooLong,
    InvalidName,
    InvalidMode,
    ClosedHandle,
    NotEmpty,
    FormatMismatch,
    Generic,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(kind) => write!(f, "I/O error: {kind:?}"),
            Self::NotMounted => f.write_str("filesystem is not mounted"),
            Self::NotFound => f.write_str("entry not found"),
            Self::AlreadyExists => f.write_str("entry already exists"),
            Self::NameTooLong => f.write_str("name exceeds 14 bytes"),
            Self::InvalidName => f.write_str("invalid virtual path or name"),
            Self::InvalidMode => f.write_str("invalid open mode"),
            Self::ClosedHandle => f.write_str("handle is closed"),
            Self::NotEmpty => f.write_str("directory is not empty"),
            Self::FormatMismatch => f.write_str("path format does not match entry type"),
            Self::Generic => f.write_str("filefs operation failed"),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(value: io::Error) -> Self {
        Self::Io(value.kind())
    }
}
