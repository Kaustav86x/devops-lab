# terraform block ( required providers declaration needs to exists in evrey module that uses that provider )
terraform {
    required_providers {
        docker = {
            source = "kreuzwerker/docker"
            version = "4.5.0"
        }
    }
}

# The provider blocks is being removed
# resource blocks

# resource block A - Image
# pulling the image
resource "docker_image" "registry" {
    name = var.registry_image
}

# resource block B - Container
# creating the container
resource "docker_container" "registry_container" {
    image = docker_image.registry.image_id
    name = var.registry_container

    ports {
        internal = var.port
        external = var.port
    }
}

