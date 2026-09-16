# Baikal Helm chart

Deploys [Baikal](https://sabre.io/baikal/) (CalDAV + CardDAV) on Kubernetes using the
[`ckulka/baikal`](https://github.com/ckulka/baikal-docker) nginx image against an
**external MySQL/MariaDB** server.

## Quick start

```sh
helm install baikal ./helm/baikal \
  --set database.host=mariadb.db.svc.cluster.local \
  --set database.password='changeme' \
  --set config.adminPassword='changeme' \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host=baikal.example.com \
  --set ingress.tls[0].secretName=baikal-tls \
  --set ingress.tls[0].hosts[0]=baikal.example.com
```

## Database schema

The chart does **not** create the schema. Baikal only creates its tables from the web
installer, which is skipped when `config.manage=true`. Create the database and load
`Core/Resources/Db/MySQL/db.sql` once before the first start:

```sh
mysql -h "$DB_HOST" -u root -p -e 'CREATE DATABASE IF NOT EXISTS baikal'
kubectl exec deploy/baikal -- cat /var/www/baikal/Core/Resources/Db/MySQL/db.sql \
  | mysql -h "$DB_HOST" -u baikal -p baikal
```

Baikal also needs a `.well-known` mapping and the `Authorization` header to reach PHP;
both are already handled by the nginx image.

## Configuration

`config.manage=true` (default) renders `config/baikal.yaml` from values into a Secret.
An init container copies it into an `emptyDir` because Baikal refuses to start unless
that file is writable by the web server user (`config.fileOwner`, `33:33` by default).

Consequence: changes made in **Admin → Settings** apply at runtime but are reverted on
the next pod restart. Values are the source of truth. To keep panel edits, mount a PVC
on `/var/www/baikal/config`:

```yaml
extraVolumes:
  - name: baikal-config
    persistentVolumeClaim:
      claimName: baikal-config
extraVolumeMounts:
  - name: baikal-config
    mountPath: /var/www/baikal/config
```

`config.manage=false` skips seeding and lets the web installer run instead. Without a
PVC its output is lost on restart, so it is only useful for one-off testing.

Users, calendars and address books live in the database and are unaffected by any of this.

## Secrets

| Value | Behaviour |
| --- | --- |
| `database.password` | Stored in the chart-managed Secret under `mysql-password`. |
| `database.existingSecret` / `database.existingSecretPasswordKey` | Read the password from an existing Secret instead. The init container substitutes it into `baikal.yaml`. |
| `config.adminPassword` | Hashed by the chart as `sha256("admin:<authRealm>:<adminPassword>")`. |
| `config.adminPasswordHash` | Use a precomputed hash and keep the plaintext out of values. |
| `config.encryptionKey` | If empty, the existing Secret value is reused, otherwise a random 32-char key is generated. |
| `config.existingSecret` | Use a Secret you manage yourself holding the full `baikal.yaml` key. |

## Values

See [values.yaml](values.yaml). Notable ones:

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` / `image.variant` | `ckulka/baikal` / `nginx` | Tag defaults to `<appVersion>-<variant>`. |
| `config.authType` | `Digest` | `Digest`, `Basic` or `Apache`. Use `Basic` only behind TLS. |
| `config.baseUri` | `""` | Set when Baikal is not served from the host root, e.g. `/baikal/`. |
| `ingress.aliasPaths` | `[]` | Extra prefixes the same Baikal answers on, stripped at the ingress. Traefik only. See below. |
| `ingress.wellKnownRedirect.enabled` | `false` | Redirect `/.well-known/ca(l\|rd)dav` to `dav.php` at the ingress. See below. |
| `ingress.wellKnownRedirect.controller` | `nginx` | `nginx` or `traefik`. |
| `database.port` | `3306` | Appended to `mysql_host` as `:port` only when different from 3306. |

## Alias paths

Clients already configured against a Baikal served under a path — `/baikal/dav.php/…`
is the usual one — keep working without being reconfigured:

```yaml
ingress:
  aliasPaths:
    - /baikal
```

Each alias is added to **every** host in `ingress.hosts` and to a `stripPrefix`
Middleware chained ahead of the chart's own, so the prefix is gone before the request
reaches the container, which serves from the root either way. Traefik only: on an
nginx ingress the chart fails rather than render a Middleware nothing reads.

**Leave `config.baseUri` empty when you use this**, however tempting it looks. An
alias is stripped before PHP sees it while `base_uri` asserts PHP will see it, and
SabreDAV rejects the contradiction on every DAV request:

```
LogicException: Requested uri (/dav.php/) is out of base uri (/baikal/dav.php/)
```

The web UI still answers `200` while that happens, so it reads as a working Baikal
whose address books are all broken.

The consequence of an empty `base_uri` is that every `href` Baikal emits is
unprefixed. A client that opens `/baikal/dav.php/addressbooks/…` gets its collection
and then follows links under `/dav.php/…`, so **route the root as well** — an alias
is a way in, not a second installation. `config.baseUri` is for the other case
entirely: a server in front that already mounts Baikal at that path and passes it
through.

## .well-known redirects

The image already redirects `/.well-known/caldav` and `/.well-known/carddav`, but it
answers with a `302` to an absolute URL that drops the port. Behind an ingress on 443
that is harmless. Set `ingress.wellKnownRedirect.enabled=true` to do it at the ingress
instead:

- `controller: nginx` adds a `configuration-snippet` annotation. ingress-nginx must run
  with `allow-snippet-annotations=true`.
- `controller: traefik` creates a `redirectRegex` Middleware and references it from a
  `traefik.ingress.kubernetes.io/router.middlewares` annotation. Set
  `ingress.traefikApiVersion` to `traefik.containo.us/v1alpha1` on Traefik v2. If the
  router already needs other middlewares, list them in `ingress.traefikMiddlewares`;
  they are chained ahead of everything the chart adds.

Both emit a `301`, not the `308` Baikal itself uses. Clients treat them the same here
because the redirect only ever targets `GET`/`PROPFIND` discovery requests.

## Scaling

`replicaCount` above 1 is safe with MySQL: state lives in the database and the config
`emptyDir` is seeded identically in every pod. It is not safe if you mount a
ReadWriteOnce PVC on `/var/www/baikal/config`.
