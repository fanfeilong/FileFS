use crate::error::{Error, Result};
use crate::types::{FileSystem, BLOCK_NAME_MAX_SIZE, ROOT_BLOCKINDEX, TXN_NONE};

impl FileSystem {
    pub(crate) fn active_pwd(&self) -> &str {
        if self.tmp.state == TXN_NONE {
            &self.pwd
        } else {
            &self.tmp.pwd
        }
    }

    pub(crate) fn active_pwd_blockindex(&self) -> u32 {
        if self.tmp.state == TXN_NONE {
            self.pwd_blockindex
        } else {
            self.tmp.pwd_blockindex
        }
    }

    fn split_virtual_path<'a>(&self, path: &'a str) -> Result<(bool, Vec<&'a str>, bool)> {
        if path.is_empty() {
            return Err(Error::InvalidName);
        }
        let absolute = path.starts_with('/');
        let trailing = path.ends_with('/') && path != "/";
        let mut components = Vec::new();
        for comp in path.split('/') {
            if comp.is_empty() {
                continue;
            }
            if comp.len() > BLOCK_NAME_MAX_SIZE {
                return Err(Error::NameTooLong);
            }
            components.push(comp);
        }
        Ok((absolute, components, trailing))
    }

    fn push_pwd_component(mut pwd: String, component: &str) -> String {
        match component {
            "." => pwd,
            ".." => {
                if pwd == "/" {
                    return pwd;
                }
                let trimmed = pwd.trim_end_matches('/');
                if let Some(idx) = trimmed.rfind('/') {
                    if idx == 0 {
                        "/".to_string()
                    } else {
                        format!("{}/", &trimmed[..idx])
                    }
                } else {
                    "/".to_string()
                }
            }
            name => {
                if pwd != "/" && !pwd.ends_with('/') {
                    pwd.push('/');
                }
                pwd.push_str(name);
                pwd.push('/');
                pwd
            }
        }
    }

    pub(crate) fn resolve_parent_and_name(&mut self, path: &str) -> Result<(u32, String, bool)> {
        let (absolute, components, trailing) = self.split_virtual_path(path)?;
        if components.is_empty() {
            return Err(Error::InvalidName);
        }

        let mut blockindex = if absolute {
            ROOT_BLOCKINDEX
        } else {
            self.active_pwd_blockindex()
        };

        for component in &components[..components.len() - 1] {
            blockindex = self
                .find_path_blockindex(blockindex, component)?
                .ok_or(Error::NotFound)?;
        }

        Ok((blockindex, components[components.len() - 1].to_string(), trailing))
    }

    pub(crate) fn resolve_dir_block(&mut self, path: &str) -> Result<(u32, String)> {
        let (absolute, components, _) = self.split_virtual_path(path)?;
        let mut blockindex = if absolute {
            ROOT_BLOCKINDEX
        } else {
            self.active_pwd_blockindex()
        };
        let mut pwd = if absolute {
            "/".to_string()
        } else {
            self.active_pwd().to_string()
        };

        for component in components {
            blockindex = self
                .find_path_blockindex(blockindex, component)?
                .ok_or(Error::NotFound)?;
            pwd = Self::push_pwd_component(pwd, component);
        }

        Ok((blockindex, pwd))
    }

    pub fn chdir(&mut self, path: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        if path == "/" {
            if self.tmp.state == TXN_NONE {
                self.pwd = "/".to_string();
                self.pwd_blockindex = ROOT_BLOCKINDEX;
            } else {
                self.tmp.pwd = "/".to_string();
                self.tmp.pwd_blockindex = ROOT_BLOCKINDEX;
            }
            return Ok(());
        }

        let (blockindex, pwd) = self.resolve_dir_block(path)?;
        if self.tmp.state == TXN_NONE {
            self.pwd = pwd;
            self.pwd_blockindex = blockindex;
        } else {
            self.tmp.pwd = pwd;
            self.tmp.pwd_blockindex = blockindex;
        }
        Ok(())
    }

    pub fn cwd(&self) -> &str {
        self.active_pwd()
    }
}
