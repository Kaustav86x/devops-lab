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

# resource blocks

# resource block A - Image
# pulling the image
resource "docker_image" "registry" {
    name = "registry:2"
}

# resource block B - Container
# creating the container
resource "docker_container" "registry_container" {
    image = docker_image.registry.image_id
    name = "registry_container"

    ports {
        internal = "5000"
        external = "5000"
    }
}

