#[derive(Debug, rustler::NifException)]
#[module = "DenoRider.Error"]
pub struct Error {
    pub message: Option<std::string::String>,
    pub name: rustler::Atom,
}
