# port variable
variable "port" {
    description = "The internal and the external ports are the same"
    type = number
    default = 5000
}

# registry container variable
variable "registry_container" {
    description = "The name of the container will be created"
    type = string
    default = "registry_container"  
}

# Default is the fallback value used when no value is passed in by the caller

# image variable
variable "registry_image" {
    description = "The image itself used to set up the container"
    type = string
    default = "registry:2"
}                                                       