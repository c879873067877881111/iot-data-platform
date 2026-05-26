FROM eclipse-mosquitto:2.0

# passwd / acl 必須 0700 + owner mosquitto，否則 broker 印 world-readable warning
# 且 mosquitto 2.1+ 會直接 refuse to load。
# 官方 docker-entrypoint.sh 只做 chown 不做 chmod，所以權限要在 build 時烙進去。
# conf 本身不含 secret，0644 即可。
# uid/gid 1883 = mosquitto user（image 內 /etc/passwd 確認）
COPY --chmod=0700 --chown=1883:1883 config/passwd          /mosquitto/config/passwd
COPY --chmod=0700 --chown=1883:1883 config/acl             /mosquitto/config/acl
COPY --chown=1883:1883              config/mosquitto.conf  /mosquitto/config/mosquitto.conf
