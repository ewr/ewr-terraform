resource "aws_db_subnet_group" "ewr_is_db" {
    name = "ewr_is_db"
    subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "aws_security_group" "ewr_is_db" {
    vpc_id = aws_vpc.app_vpc.id

    ingress {
        protocol = "tcp"
        from_port = 3306
        to_port = 3306
        cidr_blocks = ["0.0.0.0/0"]
        security_groups = [aws_security_group.egress_all.id]
    }

    ingress {
        protocol = "tcp"
        from_port = 6379
        to_port = 6379
        cidr_blocks = ["0.0.0.0/0"]
        security_groups = [aws_security_group.egress_all.id]
    }
}

resource "aws_db_instance" "ewr_is" {
    identifier = "ewr-is-production"
    allocated_storage = 10
    engine = "mysql"
    engine_version = "8.0"
    instance_class = "db.t3.micro"
    db_subnet_group_name = aws_db_subnet_group.ewr_is_db.name
    name = "ewr_is"
    storage_type = "gp2"
    username = "ewr"
    # not ideal to stick a password here, but this is buried in the VPC 
    # private subnet, so the risk doesn't seem too high.
    # TODO: figure out a better way
    password = "hbTrrgZ16lo6T2mkJIyj"
    skip_final_snapshot = true
    vpc_security_group_ids = [aws_security_group.ewr_is_db.id]
}

# resource "aws_ssm_parameter" "mysql_host" {
#     name = "ewr/mysql_host"
#     type = "String"
#     value = aws_db_instance.ewr_is.address
# }

resource "aws_elasticache_subnet_group" "ewr_is_redis" {
    name = "ewr-is-redis-subnet"
    subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "aws_elasticache_cluster" "ewr_is_redis" {
    cluster_id = "ewr-is-redis"
    engine = "redis"
    node_type = "cache.t4g.micro"
    num_cache_nodes = 1
    parameter_group_name = "default.redis6.x"
    engine_version = "6.x"
    port = 6379
    security_group_ids = [aws_security_group.ewr_is_db.id]
    subnet_group_name = aws_elasticache_subnet_group.ewr_is_redis.id
}