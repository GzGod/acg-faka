#!/bin/sh
set -e

# ── 0) Railway $PORT 支持 ─────────────────────────────────────────────────
# Railway 注入 $PORT，nginx 默认监听 80。用 sed 动态替换。
if [ -n "${PORT:-}" ] && [ "${PORT}" != "80" ]; then
    sed -i "s/listen 80 default_server;/listen ${PORT} default_server;/g; s/listen \[::\]:80 default_server;/listen [::]:${PORT} default_server;/g" \
        /etc/nginx/nginx.conf
fi

# ── 0b) 注入默认主题（仅在数据库可用后执行，见下方 wait-db） ─────────────────
ACG_DEFAULT_THEME="${ACG_DEFAULT_THEME:-AIBlue}"
export ACG_DEFAULT_THEME

cd /var/www/html

DATA=/data
SKEL=/opt/acg-skel

# ── 1) 播种数据卷 ────────────────────────────────────────────────────────────
# 站点里所有会被写入的目录都软链到 /data，挂一个卷就能保住全部数据。
# 首次启动时把镜像里烘好的原始内容（空白配置、Install.sql、Cartoon 模板…）复制过去。
for name in config install assets_cache plugins pay themes runtime; do
    if [ ! -e "${DATA}/${name}" ]; then
        cp -a "${SKEL}/${name}" "${DATA}/${name}"
    fi
done

mkdir -p \
    "${DATA}/runtime/log" "${DATA}/runtime/plugin" "${DATA}/runtime/request" \
    "${DATA}/runtime/tmp" "${DATA}/runtime/view" "${DATA}/runtime/waf" "${DATA}/runtime/session" \
    "${DATA}/install/OS" "${DATA}/install/Update" \
    "${DATA}/secrets"
chmod 700 "${DATA}/secrets"

# 网站公开路径 /favicon.ico 是指向 assets/cache/favicon.ico 的软链，实际图片在数据卷里；
# 后台"基础设置"上传的 Logo 写进的就是这个文件，容器重启、重建都不会丢
if [ ! -f "${DATA}/assets_cache/favicon.ico" ] && [ -f /usr/local/share/acg-faka/favicon.ico ]; then
    cp /usr/local/share/acg-faka/favicon.ico "${DATA}/assets_cache/favicon.ico"
fi
if [ ! -L favicon.ico ]; then
    # 兼容旧版保存逻辑：它会用上传的图片把这个软链替换成普通文件，图片只留在容器可写层。
    # 同一个容器重启时先把它迁进数据卷，再恢复软链（镜像里的 favicon.ico 本身就是软链，不会误伤）
    if [ -f favicon.ico ] && [ -s favicon.ico ]; then
        cp favicon.ico "${DATA}/assets_cache/favicon.ico"
    fi
    rm -f favicon.ico
    ln -s assets/cache/favicon.ico favicon.ico
fi

# HTTPS 相关：nginx 片段与证书都放数据卷，容器重建/换镜像后不丢。
mkdir -p "${DATA}/nginx" "${DATA}/ssl"

chown -R www-data:www-data \
    "${DATA}/config" "${DATA}/install" "${DATA}/assets_cache" \
    "${DATA}/plugins" "${DATA}/pay" "${DATA}/themes" "${DATA}/runtime"

# ── 2) 决定用内置数据库还是外接数据库 ────────────────────────────────────────
# 用户自己给了 ACG_DB_HOST（compose 里指向 mysql 服务，或者手工接外部库）就用他的，
# 什么都没给就启动镜像自带的 MariaDB + Redis —— 单容器 docker run 也能全自动。
BUNDLED=0
if [ -z "${ACG_DB_HOST:-}" ]; then
    BUNDLED=1
fi

if [ "${BUNDLED}" = "1" ]; then
    MYSQL_DIR="${DATA}/mysql"
    PW_FILE="${DATA}/secrets/mysql_app"

    mkdir -p "${MYSQL_DIR}" "${DATA}/redis" /run/mysqld
    chown -R mysql:mysql "${MYSQL_DIR}" /run/mysqld
    chown -R redis:redis "${DATA}/redis"

    if [ ! -d "${MYSQL_DIR}/mysql" ]; then
        echo "[acg-faka] 首次启动：初始化内置数据库…"
        mariadb-install-db --user=mysql --datadir="${MYSQL_DIR}" \
            --auth-root-authentication-method=normal --skip-test-db >/dev/null 2>&1

        # 密码随机生成后只落在数据卷里，镜像本身不带任何默认密码
        PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
        printf '%s' "${PW}" > "${PW_FILE}"
        chmod 600 "${PW_FILE}"

        # 建库建号必须让服务器真正跑起来：--bootstrap 隐含 --skip-grant-tables，
        # CREATE USER / GRANT 在那个模式下会直接报 1290。
        # 所以照官方镜像的做法，用 socket 临时起一次，建完立刻关掉。
        INIT_SOCK=/run/mysqld/init.sock
        mariadbd --user=mysql --datadir="${MYSQL_DIR}" \
            --skip-networking --socket="${INIT_SOCK}" --skip-log-bin >/dev/null 2>&1 &
        INIT_PID=$!

        READY=0
        for _ in $(seq 1 60); do
            if mariadb-admin --socket="${INIT_SOCK}" -u root ping >/dev/null 2>&1; then READY=1; break; fi
            sleep 1
        done
        if [ "${READY}" != "1" ]; then
            echo "[acg-faka] 内置数据库启动失败" >&2
            exit 1
        fi

        # 授权主机写 '%'：程序走 TCP 连 127.0.0.1，而 MySQL 的 'localhost'
        # 只匹配 unix socket，用 localhost 授权会连不上。
        mariadb --socket="${INIT_SOCK}" -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`acg_faka\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'acg'@'%' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON \`acg_faka\`.* TO 'acg'@'%';
FLUSH PRIVILEGES;
SQL

        mariadb-admin --socket="${INIT_SOCK}" -u root shutdown
        wait "${INIT_PID}" 2>/dev/null || true

        chown -R mysql:mysql "${MYSQL_DIR}"
        echo "[acg-faka] 内置数据库已就绪（库 acg_faka / 用户 acg，密码随机生成）"
    fi

    # 交给 supervisord 托管；priority 比 php-fpm/nginx 小，先起
    cat > /etc/supervisor/conf.d/acg-bundled.conf <<'CONF'
[program:mariadb]
command=/usr/sbin/mariadbd --user=mysql --datadir=/data/mysql --bind-address=127.0.0.1 --skip-name-resolve --skip-log-bin --innodb-buffer-pool-size=256M --max-connections=200
priority=1
autostart=true
autorestart=true
startretries=3
stopsignal=TERM
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis]
command=/usr/bin/redis-server --dir /data/redis --appendonly yes --bind 127.0.0.1 --save ""
priority=2
autostart=true
autorestart=true
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
CONF

    # 安装向导据此自动填好连接信息，用户一个字都不用输
    export ACG_DB_HOST=127.0.0.1
    export ACG_DB_PORT=3306
    export ACG_DB_DATABASE=acg_faka
    export ACG_DB_USERNAME=acg
    export ACG_DB_PASSWORD_FILE="${PW_FILE}"
    export ACG_DB_PREFIX=acg_
    export ACG_REDIS_HOST=127.0.0.1
    # 让 php-fpm 等 MariaDB 就绪再启动，见 docker/wait-db.sh
    export ACG_WAIT_DB=1
else
    # 外接数据库模式：内置服务一律不启动
    rm -f /etc/supervisor/conf.d/acg-bundled.conf
fi

# ── 3) 会话后端 ──────────────────────────────────────────────────────────────
# 有 redis 就用 redis，没有退回文件。写死在 php.ini 里的话，没有 redis 的环境
# session_start() 会直接失败 —— 安装向导不开 session 所以看不出来，一登录后台就炸。
SESSION_INI=/usr/local/etc/php/conf.d/zz-acg-session.ini
if [ -n "${ACG_REDIS_HOST:-}" ]; then
    printf 'session.save_handler = redis\nsession.save_path = "tcp://%s:%s?database=%s&prefix=acg_sess:"\n' \
        "${ACG_REDIS_HOST}" "${ACG_REDIS_PORT:-6379}" "${ACG_REDIS_DB:-1}" > "${SESSION_INI}"
else
    printf 'session.save_handler = files\nsession.save_path = "/var/www/html/runtime/session"\n' > "${SESSION_INI}"
fi

# ── 4) 线程管理器：装了就交给 supervisord 托管 ──────────────────────────────
#
# 插件自带的 `service.sh start` 是 nohup 甩出去的野进程：容器一重建就没了、
# 崩了也没人拉、docker stop 时直接被 SIGKILL（任务不收尾）。
# 这个钩子把它登记成 supervisord 的程序，和 nginx / php-fpm 一个待遇。
#
# 同一个脚本插件那边装完也会调一次，所以「装完立刻被托管」，不用重启容器。
if [ -x /usr/local/bin/acg-supervise-threadmanager ]; then
    /usr/local/bin/acg-supervise-threadmanager || true
fi

# 内置数据库的密码放在只读的密钥文件里，读出来变成普通环境变量交给 php-fpm
# （pool 里 clear_env=no），安装向导才拿得到。
if [ -n "${ACG_DB_PASSWORD_FILE:-}" ] && [ -r "${ACG_DB_PASSWORD_FILE}" ]; then
    ACG_DB_PASSWORD="$(cat "${ACG_DB_PASSWORD_FILE}")"
    export ACG_DB_PASSWORD
fi

if [ -n "${ACG_DB_HOST:-}" ]; then
    # Write database.php config file (acg-faka reads this, not env vars)
    DB_CFG="${DATA}/config/database.php"
    mkdir -p "${DATA}/config"
    cat > "${DB_CFG}" <<DBCONF
<?php
declare(strict_types=1);
return [
    'driver'    => 'mysql',
    'host'      => '${ACG_DB_HOST}',
    'port'      => ${ACG_DB_PORT:-3306},
    'database'  => '${ACG_DB_DATABASE}',
    'username'  => '${ACG_DB_USERNAME}',
    'password'  => '${ACG_DB_PASSWORD}',
    'charset'   => 'utf8mb4',
    'collation' => 'utf8mb4_general_ci',
    'prefix'    => '${ACG_DB_PREFIX:-acg_}',
];
DBCONF
    echo "[acg-faka] database.php written."

    # Synchronously wait for MySQL, then import schema + set theme + create admin.
    # Must finish BEFORE php-fpm starts: acg-faka caches config in runtime/config
    # (binary-packed), and that cache is seeded from the skel with the Cartoon theme.
    # If the first request reads that stale cache before our UPDATE lands, the site
    # stays on Cartoon regardless of what the DB says.
    php -r "
        \$host = getenv('ACG_DB_HOST');
        \$port = getenv('ACG_DB_PORT') ?: 3306;
        \$db   = getenv('ACG_DB_DATABASE');
        \$user = getenv('ACG_DB_USERNAME');
        \$pass = getenv('ACG_DB_PASSWORD');
        \$pre  = getenv('ACG_DB_PREFIX') ?: 'acg_';
        \$lock = '/var/www/html/kernel/Install/Lock';

        // Wait for MySQL to accept connections (up to ~60s)
        \$pdo = null;
        for (\$i = 0; \$i < 60; \$i++) {
            try {
                \$pdo = new PDO(\"mysql:host=\$host;port=\$port;dbname=\$db;charset=utf8mb4\", \$user, \$pass,
                    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                break;
            } catch (Exception \$e) {
                if (\$i === 0) echo '[acg-faka] Waiting for MySQL...' . PHP_EOL;
                sleep(1);
            }
        }
        if (\$pdo === null) {
            echo '[acg-faka] ERROR: MySQL not reachable after 60s' . PHP_EOL;
        } else {
            echo '[acg-faka] MySQL connected.' . PHP_EOL;

            // Check if already installed (config table exists)
            \$tables = \$pdo->query('SHOW TABLES LIKE \"' . \$pre . 'config\"')->fetchAll();
            if (empty(\$tables)) {
                echo '[acg-faka] Running auto-install...' . PHP_EOL;
                \$sql = file_get_contents('/var/www/html/kernel/Install/Install.sql');
                \$sql = str_replace('__PREFIX__', \$pre, \$sql);
                foreach (array_filter(array_map('trim', explode(';', \$sql))) as \$stmt) {
                    if (\$stmt) \$pdo->exec(\$stmt);
                }
                echo '[acg-faka] SQL imported.' . PHP_EOL;
            } else {
                echo '[acg-faka] DB already installed, skipping SQL import.' . PHP_EOL;
            }

            // Set AIBlue theme (column is \`key\`, not \`name\`)
            \$tbl = \$pre . 'config';
            \$pdo->exec(\"UPDATE \`\$tbl\` SET \`value\`='AIBlue' WHERE \`key\`='user_theme'\");
            \$pdo->exec(\"UPDATE \`\$tbl\` SET \`value\`='AIBlue' WHERE \`key\`='user_mobile_theme'\");
            echo '[acg-faka] Theme set to AIBlue.' . PHP_EOL;

            // Create default admin account if none exists
            \$adminTbl = \$pre . 'manage';
            \$existing = \$pdo->query(\"SELECT COUNT(*) FROM \`\$adminTbl\`\")->fetchColumn();
            if ((int)\$existing === 0) {
                \$email    = getenv('ACG_ADMIN_EMAIL') ?: 'admin@aishop.com';
                \$password = getenv('ACG_ADMIN_PASSWORD') ?: 'Admin@123456';
                \$hash     = password_hash(\$password, PASSWORD_BCRYPT);
                \$salt     = substr(md5(uniqid()), 0, 32);
                \$now      = date('Y-m-d H:i:s');
                \$stmt = \$pdo->prepare(\"INSERT INTO \`\$adminTbl\` (email,password,salt,nickname,status,type,create_time) VALUES (?,?,?,'Admin',1,0,?)\");
                \$stmt->execute([\$email, \$hash, \$salt, \$now]);
                echo '[acg-faka] Admin account created: ' . \$email . PHP_EOL;
            } else {
                echo '[acg-faka] Admin account already exists.' . PHP_EOL;
            }

            // Write install Lock file
            if (!file_exists(\$lock)) {
                file_put_contents(\$lock, date('Y-m-d H:i:s'));
                echo '[acg-faka] Lock file written.' . PHP_EOL;
            } else {
                echo '[acg-faka] Lock file already exists.' . PHP_EOL;
            }
        }
    " 2>&1

    # Delete the stale config cache so the first request rebuilds it from DB.
    # The skel ships a runtime/config baked with the Cartoon theme; without this
    # deletion, Config::cached('user_theme') returns Cartoon from the cache file
    # and never notices the DB now says AIBlue.
    rm -f "${DATA}/runtime/config"
    echo "[acg-faka] Stale config cache purged."
fi

exec "$@"
