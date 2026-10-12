//! How a command ends. Commands return instead of calling `exit`: that way
//! the registry lock, temporary index files and the like are released by
//! their destructors even when the command fails halfway.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exit(pub i32);

pub type Res<T = ()> = Result<T, Exit>;

/// Prints the reason as an error line and ends the command with status 1.
#[macro_export]
macro_rules! die {
    ($($arg:tt)*) => {{
        $crate::ui::err(format!($($arg)*));
        return Err($crate::error::Exit(1));
    }};
}

/// Ends the command with a status and nothing printed.
pub fn exit<T>(code: i32) -> Res<T> {
    Err(Exit(code))
}
