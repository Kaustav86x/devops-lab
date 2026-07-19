output "container_name" {
    description = "Name of the container"
    value = docker_container.registry_container.name
}

output "functional_port" {
    description = "Port the container is running on"
    value = docker_container.registry_container.ports[0].external
}