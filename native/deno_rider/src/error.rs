#[derive(Debug, rustler::NifException)]
#[module = "DenoRider.Error"]
pub struct Error {
    pub message: Option<std::string::String>,
    pub name: rustler::Atom,
    pub value: Option<std::string::String>,
}
