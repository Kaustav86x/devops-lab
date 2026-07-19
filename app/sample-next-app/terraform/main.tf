# terraform block
terraform {
    required_providers {
        docker = {
            source = "kreuzwerker/docker"
            version = "4.5.0"
        }
    }
}

# provider block
provider "docker" {
    host = "unix:///var/run/docker.sock"
}

# resource blocks stored in another main.tf file will be called from here

# module block for the variables related to registry

# module block for registry
module "local_registry" {
    source = "./modules/registry"
    registry_container = "registry_container"
    registry_image = "registry:2"              # passing the value of the image
    port = 5000
}