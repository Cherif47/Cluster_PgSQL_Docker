# Déploiement Docker Swarm + etcd + Patroni (PostgreSQL 18) + Portainer

Playbook Ansible qui, à partir de 3 instances vierges (Debian/Ubuntu), installe Docker, crée un cluster Swarm, déploie un cluster etcd à 3 nœuds, un cluster PostgreSQL 18 haute disponibilité géré par Patroni (1 leader + 2 réplicas synchrones) et Portainer.

## Lancement

Depuis WSL, dans ce dossier :

```bash
cd /home/deploy/ansible/Scripts/DOCKER
ansible swarm -m ping                      # test de connexion SSH
ansible-playbook playbook.yml --syntax-check
ansible-playbook playbook.yml              # déploiement complet
```

Le playbook est rejouable : les tâches déjà appliquées ne sont pas refaites.

Prérequis sur la machine de contrôle : Ansible, accès SSH root aux 3 nœuds, et le fichier `patroni-postgres18.tar` à côté de `playbook.yml`.

## Architecture cible

| Hôte | IP | Rôle Swarm | etcd | Patroni / PostgreSQL |
|---|---|---|---|---|
| SRV-DOCK1 | IP | manager (initialise le swarm) | etcd1 | patroni1 |
| SRV-DOCK2 | IP | manager | etcd2 | patroni2 |
| SRV-DOCK3 | IP | manager | etcd3 | patroni3 |

Les 3 nœuds sont managers Swarm (quorum Raft 2 sur 3, pas de worker). Les rôles Swarm sont indépendants des rôles Patroni (leader/réplica) : n'importe quel nœud Patroni peut devenir leader.

Les services communiquent par le réseau overlay `backend`. Les trois nœuds PostgreSQL publient le port 5432 en mode `host` sur leur serveur.

## Ordre d'exécution

Le playbook exécute 8 plays à la suite :

1. **Pré-requis Ansible** (hôtes : `swarm`, rôle `bootstrap`) : installe python3 si absent, sans collecte de facts.
2. **Installation Docker** (hôtes : `swarm`, rôle `docker`) : proxy apt et Docker, installation de Docker CE (dépôt officiel, version figée par `docker_target_version`), `curl`, `rsync`, démarrage de Docker.
3. **Initialisation du Swarm** (hôtes : `manager[0]`, soit SRV-DOCK1, rôle `swarm-manager`) : `docker swarm init`, lecture et mémorisation du token manager.
4. **Join des autres managers** (hôtes : `manager:!manager[0]`, soit SRV-DOCK2 et SRV-DOCK3, rôle `swarm-join-manager`) : rejoignent le swarm en tant que managers avec le token manager.
5. **Préparation des nœuds** (hôtes : `swarm`, rôle `node_prepare`) : répertoires de données, fichier `patroniN.yml`, chargement de l'image.
6. **Déploiement** (hôtes : `manager`, rôles `etcd`, `patroni`, `portainer`) : attente des 3 nœuds Ready, puis déploiement des stacks dans cet ordre.

7. **PgBouncer** (hôtes : `swarm`, rôle `pgbouncer`) : conteneur PgBouncer sur les 3 nœuds (voir la section PgBouncer).
8. **HAProxy + Keepalived** (hôtes : `lb`, soit SRV-DOCK1 et SRV-DOCK2, rôles `haproxy`, `keepalived`) : vérifie que `keepalived_vip` est renseignée, puis lance HAProxy et Keepalived en conteneurs sur ces deux nœuds.

Détail du play 6 :

1. `pre_tasks` : attend que les 3 nœuds soient `Ready` (`docker node ls`, 20 essais, 5 s d'intervalle).
2. `etcd` : crée le réseau `backend`, déploie la stack `pginfra`, attend que le cluster etcd soit sain (`etcdctl endpoint health --cluster`, 40 essais, 5 s).
3. `patroni` : déploie la stack `ptinfra` (3 services Patroni). Postgres 18 est inclus dans l'image et lancé par Patroni.
4. `portainer` : crée le volume `portainer_data`, déploie l'agent puis Portainer.

## Arborescence

```
DOCKER/
├── README.md                    Ce fichier
├── ansible.cfg                  Config Ansible locale
├── inventory.ini                Hôtes et groupes
├── playbook.yml                 Point d'entrée, enchaîne les plays
├── upgrade-docker.yml           Mise à jour (rolling) de Docker CE sur les nœuds existants
├── Dockerfile                   Construction de l'image patroni-postgres:18
├── patroni-postgres18.tar       Image exportée (docker save), chargée sur chaque nœud
├── group_vars/
│   └── all/vars.yml             Variables communes à tous les hôtes
├── files/                       Fichiers de stacks copiés tels quels
│   ├── etcd-stack.yml           Stack etcd (3 services)
│   ├── patroni-stack.yml        Stack Patroni (3 services)
│   ├── portainer-agent.yml      Agent Portainer (mode global)
│   └── portainer-stack.yml      Serveur Portainer
├── roles/
│   ├── bootstrap/tasks/main.yml
│   ├── docker/tasks/main.yml
│   ├── docker/defaults/main.yml
│   ├── docker/handlers/main.yml
│   ├── swarm-manager/tasks/main.yml
│   ├── swarm-join-manager/tasks/main.yml
│   ├── node_prepare/tasks/main.yml
│   ├── node_prepare/templates/patroni.yml.j2
│   ├── pgbouncer/               tasks, handlers, templates/pgbouncer.ini.j2 + userlist.txt.j2
│   ├── haproxy/                 tasks, handlers, templates/haproxy.cfg.j2
│   ├── keepalived/              tasks, handlers, files/Dockerfile, templates/keepalived.conf.j2 + chk_haproxy.sh.j2
│   ├── etcd/tasks/main.yml
│   ├── patroni/tasks/main.yml
│   └── portainer/tasks/main.yml
├── _old/                        Anciens fichiers (archive, non utilisés)
└── stack.yml                    Exemple nginx, non utilisé par le playbook
```

### Fichiers à la racine

- **`ansible.cfg`** : `inventory = inventory.ini`, `roles_path = roles`, `host_key_checking = False` (utile sur instances vierges), `timeout = 60`.
- **`inventory.ini`** : voir la section Inventaire.
- **`Dockerfile`** : image basée sur `postgres:18`, avec python3, gcc, `patroni[etcd3]` et `psycopg[binary]`. Démarre sous l'utilisateur `postgres` avec `patroni /etc/patroni/patroni.yml`. Les arguments `HTTP_PROXY` et `HTTPS_PROXY` servent uniquement au build. Pour reconstruire : `docker build --build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=... -t patroni-postgres:18 .` puis `docker save -o patroni-postgres18.tar patroni-postgres:18`.
- **`patroni-postgres18.tar`** : contient le tag `patroni-postgres:18`. Il n'y a pas de registre : le tar est copié puis chargé (`docker load`) sur chaque nœud, seulement si l'image est absente.

## Inventaire (`inventory.ini`)

- **Groupe `manager`** : SRV-DOCK1, SRV-DOCK2, SRV-DOCK3. Tous managers Swarm ; le premier du groupe (SRV-DOCK1) initialise le swarm.
- **Groupe `lb`** : SRV-DOCK1, SRV-DOCK2. Nœuds qui portent HAProxy + Keepalived (la VIP). SRV-DOCK3 n'en a pas.
- **Groupe `swarm`** : contient le groupe `manager`. Cible des plays communs.
- **Groupe `postgres`** : identique à `swarm`. Réservé pour un usage futur.
- **`ansible_host`** : IP du nœud. Adresse SSH, et adresse d'annonce du swarm pour le manager.
- **`node_id`** : 1, 2 ou 3. Sert à nommer `etcdN`, `postgresN` et `patroniN`.
- **`ansible_user`** : `root`. Utilisateur SSH, défini dans `[swarm:vars]`.

Le `node_id` doit correspondre aux contraintes `node.hostname` des stacks (`SRV-DOCK1` pour etcd1/patroni1, etc.).

## Variables (`group_vars/all/vars.yml`)

**Proxy**
- `http_proxy_url` : ``. Proxy HTTP pour apt et le démon Docker. Vide = pas de proxy.
- `https_proxy_url` : même valeur. Proxy HTTPS pour apt et le démon Docker.
- `no_proxy` : `localhost,127.0.0.1,10.38.0.0/16`. Exceptions du proxy pour le démon Docker.

**Docker**
- `docker_target_version` : `29.9.3` (défaut du rôle `docker`, `roles/docker/defaults/main.yml`). Version de Docker CE installée sur tous les nœuds ; à garder identique dans `upgrade-docker.yml`.

**Réseau**
- `backend_network` : `backend`. Nom du réseau overlay partagé par etcd et Patroni.
- `backend_subnet` : ``. Sous-réseau de cet overlay, aussi utilisé dans le `pg_hba` pour la réplication.

**Image**
- `patroni_image` : `patroni-postgres:18`. Tag de l'image attendue sur chaque nœud.
- `patroni_image_tar` : `{{ playbook_dir }}/patroni-postgres18.tar`. Chemin du tar sur la machine de contrôle.

**Réglages PostgreSQL**
- `pg_shared_buffers` : `4GB`. Paramètre `shared_buffers`.
- `pg_effective_cache_size` : `12GB`. Paramètre `effective_cache_size`.

**Mots de passe**
- `pg_superuser_password` : ``. Utilisateur ``.
- `pg_replication_password` : ``. Utilisateur ``.
- `pg_admin_password` : ``. Utilisateur `` créé au bootstrap.

**HAProxy et Keepalived**
- `keepalived_vip` : `IPV`. Adresse de la VIP ; le play 7 s'arrête si elle est vide.
- `keepalived_vip_prefix` : `24`. Longueur du masque de la VIP.
- `keepalived_interface` : interface de la route par défaut du nœud (`ansible_default_ipv4.interface`). Interface qui porte la VIP.
- `keepalived_router_id` : `51`. Identifiant VRRP, identique sur les 2 nœuds `lb`, unique dans le réseau local.
- `keepalived_auth_pass` : `pgVIP001`. Mot de passe VRRP, 8 caractères maximum.
- `keepalived_image` : `keepalived:local`. Image construite localement sur chaque nœud.
- `pg_console_user` / `pg_console_password` : `Admin_pgsql` / voir `vars.yml`. Compte de la console d'administration, créé en superuser au bootstrap Patroni. À passer en ansible-vault.
- `haproxy_allowed_sources` : par défaut `pg_hba_admin_scram` + `pg_hba_trust` (sans doublons). Seuls ces postes (et 127.0.0.1) peuvent joindre les ports 5010, 5011 et 8404 de la VIP.
- `haproxy_image` : `haproxy:3.0-alpine`.
- `haproxy_pg_rw_port` : `5010`. Écritures, dirigées vers le leader Patroni.
- `haproxy_pg_ro_port` : `5011`. Lectures, réparties sur les réplicas.
- `haproxy_stats_port` : `8404`. Page de stats HAProxy, aussi utilisée par la sonde Keepalived.

**API REST Patroni**
- `patroni_api_user` / `patroni_api_password` : `patroni` / `patroni`. Compte exigé pour les actions de modification (failover, restart). Les lectures (sondes HAProxy) restent libres.

**Réseau Docker**
- `docker_gwbridge_subnet` : `172.16.0.0/12`. Plage vue par PostgreSQL pour les connexions locales de HAProxy ; elle est autorisée en `scram-sha-256` dans le `pg_hba`.

**Accès réseau PostgreSQL**
- `pg_hba_admin_scram` : liste d'IP autorisées pour l'utilisateur `` en `scram-sha-256`.
- `pg_hba_trust` : liste d'IP autorisées en `trust` pour tous les utilisateurs.

À faire avant la production : chiffrer les mots de passe avec `ansible-vault` et revoir la liste `pg_hba_trust`.

`shared_buffers` et `effective_cache_size` doivent être adaptés à la RAM des nœuds.

## Rôles

### `bootstrap`
Tâche `raw` : installe python3 s'il manque (`apt-get update && apt-get install -y python3`). Elle s'exécute sans collecte de facts, car Ansible a besoin de python sur la cible.

### `docker`
- Si un proxy est défini : crée `/etc/apt/apt.conf.d/95proxy` et le drop-in `/etc/systemd/system/docker.service.d/http-proxy.conf` (avec `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`). La modification du drop-in déclenche le handler `Redémarrer Docker`.
- Installe `ca-certificates`, `curl`, `gnupg`, `rsync`, ajoute le dépôt officiel Docker (clé GPG téléchargée via le proxy), puis installe `docker-ce` et `docker-ce-cli` en version `docker_target_version`, `containerd.io`, `docker-buildx-plugin` et `docker-compose-plugin`.
- Fige `docker-ce` et `docker-ce-cli` (`hold`) pour éviter une mise à jour involontaire.
- Active et démarre le service `docker`.

### `swarm-manager`
Lit l'état du swarm (`docker info`), initialise le swarm avec `--advertise-addr <ansible_host>` s'il n'est pas déjà `active`, lit le token manager et le mémorise dans la variable `swarm_manager_token`. Exécuté uniquement sur le premier manager.

### `swarm-join-manager`
Sur les managers autres que le premier : si le nœud n'est pas `active`, exécute `docker swarm join` avec le token manager et `--advertise-addr <ansible_host>` vers `<ip du premier manager>:2377`. Cela suppose que le play `swarm-manager` a été exécuté dans la même exécution.

Si l'IP d'un manager change (`ansible_host` dans l'inventaire), le rôle détecte que l'adresse annoncée diffère : il rétrograde le nœud, le fait quitter le swarm, le retire de la liste (`docker node rm`), puis le rejoint avec la nouvelle adresse.

### `haproxy`
Sur les nœuds du groupe `lb` (2 nœuds) : génère `/srv/docker/haproxy/haproxy.cfg`, la valide (`haproxy -c`), puis lance le conteneur `haproxy` (`--network host`, `--restart unless-stopped`). Un changement de configuration redémarre le conteneur.
- Port `haproxy_pg_rw_port` : le serveur retenu est celui dont l'API Patroni répond 200 sur `/primary` (le leader).
- Port `haproxy_pg_ro_port` : les serveurs dont l'API répond 200 sur `/replica`, en round-robin.
- Les serveurs sont les 3 nœuds (port PostgreSQL 5432, sonde sur le port 8008).

### `keepalived`
Sur les nœuds du groupe `lb` (2 nœuds) : construit l'image `keepalived:local` (Alpine + keepalived + bash, avec le proxy en argument de build), génère la configuration et la sonde, puis lance le conteneur `keepalived` (`--network host`, capacités `NET_ADMIN`, `NET_RAW`, `NET_BROADCAST`).
- Tous les nœuds démarrent en `BACKUP` ; la priorité décroît avec le `node_id` (150 pour DOCK1, 140 pour DOCK2), donc DOCK1 porte la VIP en fonctionnement normal et DOCK2 est en secours.
- VRRP en unicast entre les 2 IP des nœuds `lb` (pas de multicast).
- Sonde `chk_haproxy.sh` : si HAProxy ne répond pas sur son port de stats, le nœud perd la VIP au profit d'un autre.

### `node_prepare`
Sur chacun des 3 nœuds :
- crée `/srv/docker` ;
- crée `/srv/docker/etcd<node_id>` (données etcd) ;
- crée `/srv/docker/postgres<node_id>` (données PostgreSQL), propriétaire uid/gid 999 (utilisateur `postgres` de l'image), droits `0700` ;
- génère `/srv/docker/patroni<node_id>.yml` depuis le template `patroni.yml.j2` ;
- si l'image `patroni-postgres:18` est absente : copie le tar dans `/root`, fait `docker load`, puis supprime le tar.

### `etcd`
- Crée le réseau overlay `backend` (attachable, sous-réseau `backend_subnet`) s'il n'existe pas.
- Copie `files/etcd-stack.yml` vers `/root/` et déploie la stack `pginfra`.
- Attend que les 3 membres etcd répondent sainement.

### `patroni`
Copie `files/patroni-stack.yml` vers `/root/` et déploie la stack `ptinfra`.

### `portainer`
Crée le volume `portainer_data`, copie les deux stacks, déploie `portainer-agent` puis `portainer`.

## Stacks (`files/`)

### `etcd-stack.yml` (stack `pginfra`)
Trois services `etcd1`, `etcd2`, `etcd3` (image `quay.io/coreos/etcd:v3.5.21`), chacun épinglé sur un nœud (`node.hostname`). Données dans `/srv/docker/etcdN`. Cluster formé avec `--initial-cluster-state=new` et le token `TEST-CLUSTER`. Clients sur le port 2379, pairs sur 2380. Réseau externe `backend`.

### `patroni-stack.yml` (stack `ptinfra`)
Trois services `patroni1..3` (image `patroni-postgres:18`), chacun épinglé sur un nœud. Port 5432 publié en mode `host`. Montages : `/srv/docker/postgresN` vers `/var/lib/postgresql/data` et `/srv/docker/patroniN.yml` vers `/etc/patroni/patroni.yml` (lecture seule). Réseau externe `backend`.

### `portainer-agent.yml` (stack `portainer-agent`)
Agent `portainer/agent:lts` en mode `global` (un par nœud). Crée le réseau overlay `portainer_agent`, attachable.

### `portainer-stack.yml` (stack `portainer`)
Serveur `portainer/portainer-ce:lts` sur le manager, connecté à l'agent par `-H tcp://tasks.agent:9001 --tlsskipverify`. Ports 9000 et 9443. Données dans le volume externe `portainer_data`.

## Template Patroni (`roles/node_prepare/templates/patroni.yml.j2`)

Un seul template pour les 3 nœuds. Seul le nom change (`patroni<node_id>`).

La section `bootstrap` n'est utilisée que par le nœud qui initialise le cluster (le premier à obtenir le verrou dans etcd). Les autres l'ignorent et clonent le leader par `basebackup`. Le nœud Swarm manager n'est donc pas forcément le leader PostgreSQL.

- **`scope` / `namespace` / `name`** : cluster `postgres`, clé etcd `/db/`, nom du nœud `patroniN`.
- **`restapi`** : API REST sur le port 8008.
- **`etcd3.hosts`** : `etcd1:2379`, `etcd2:2379`, `etcd3:2379`.
- **`bootstrap.dcs`** :
  - `ttl: 30`, `loop_wait: 10`, `retry_timeout: 10`
  - `maximum_lag_on_failover: 1048576`
  - `check_timeline`, `use_pg_rewind`, `use_slots`
  - `synchronous_mode: true`, `synchronous_node_count: 2`
- **`bootstrap.dcs.postgresql.parameters`** :
  - timeouts et keepalives TCP
  - archivage désactivé
  - `shared_buffers` et `effective_cache_size` (variables)
  - workers parallèles
  - `wal_level: replica`, `hot_standby`, `wal_keep_size: 1024MB`
- **`bootstrap.initdb`** : encodage UTF8, `data-checksums`.
- **`bootstrap.pg_hba`** :
  - accès local en `peer`, localhost en `scram-sha-256`
  - réplication (`rep_user`) et `postgres` depuis `backend_subnet` en `scram-sha-256`
  - `Admin_pgsql` en `scram-sha-256` pour les IP de `pg_hba_admin_scram`
  - `trust` pour les IP de `pg_hba_trust`
- **`bootstrap.post_bootstrap`** : commande `psql` lancée une fois à l'initialisation, qui crée `pg_console_user` (superuser) et `admin` (createrole, createdb). Patroni ≥ 4.0 ne gère plus `bootstrap.users`.
- **`postgresql`** :
  - écoute sur `*:5432`, `connect_address` `patroniN:5432`
  - `data_dir` : `/var/lib/postgresql/data`
  - méthode de réplica : `basebackup`
  - comptes `rep_user` et `postgres` (mots de passe en variables)
- **`postgresql.parameters`** : socket Unix dans `/var/run/postgresql`, journaux dans `<data_dir>/log/postgresql.log`.
- **`tags`** : aucun nœud exclu du failover.

Avec `synchronous_mode` activé, Patroni retombe en asynchrone si aucun réplica synchrone n'est disponible. Il n'y a pas de mode strict.

## HAProxy et VIP

HAProxy et Keepalived tournent sur 2 nœuds (groupe `lb`) : le nœud qui porte la VIP est actif, l'autre est en secours. Ils ne tournent pas dans Swarm : Keepalived a besoin du réseau `host` et de capacités réseau que `docker stack deploy` n'accorde pas. Ils sont lancés par Ansible avec `docker run` sur les nœuds `lb`.

Les applications se connectent à la VIP :
- `<VIP>:5010` : connexion au leader PostgreSQL (lecture/écriture) ;
- `<VIP>:5011` : connexion à un réplica (lecture seule) ;
- `http://<VIP>:8404/stats` : état des serveurs vus par HAProxy.

### Console d'administration (pgAdmin, DBeaver...)

Paramètres de connexion depuis un poste autorisé :
- hôte : la VIP ; port : `5010` (leader, lecture/écriture) ; base : `postgres` ;
- utilisateur : `pg_console_user` (`Admin_pgsql`), mot de passe `pg_console_password`.

Deux points propres au passage par HAProxy :
- PostgreSQL ne voit plus l'IP du poste mais celle du nœud HAProxy. Le filtrage par IP est donc fait par HAProxy (`haproxy_allowed_sources`). Le poste doit être dans cette liste, sinon la connexion est coupée avant d'atteindre PostgreSQL.
- Les règles `trust` par IP du `pg_hba` ne s'appliquent plus pour ces connexions : le mot de passe est toujours demandé (`scram-sha-256`).

Le compte `Admin_pgsql` n'est créé qu'à l'initialisation du cluster. Sur un cluster déjà initialisé, le créer à la main depuis le leader :

```sql
CREATE ROLE "" LOGIN SUPERUSER CREATEROLE CREATEDB PASSWORD '...';
```

Les ports 5010, 5011 et 8404 ne doivent pas être utilisés par ailleurs sur les nœuds. Patroni publie 5432 et 8008 en mode `host` sur chaque nœud (HAProxy s'y connecte).

## PgBouncer

Un conteneur `pgbouncer` (réseau `host`, `--restart unless-stopped`) tourne sur chacun des 3 nœuds (play « Déploiement PgBouncer », rôle `pgbouncer`, avant HAProxy).

```
client -> VIP:6432 (HAProxy) -> PgBouncer :6433 (3 nœuds, leastconn) -> VIP:5010 (HAProxy, leader) -> PostgreSQL
```

- **Les applications se connectent à `<VIP>:6432`** (`haproxy_pgbouncer_port`). Les ports 5010 et 5011 restent ouverts : 5010 est utilisé par PgBouncer pour joindre le leader, 5011 reste disponible pour les lectures directes (sans pooling).
- PgBouncer écoute en local sur `6433` (`pgbouncer_port`), car HAProxy occupe déjà `6432` sur les nœuds `lb`.
- Configuration : `/srv/docker/pgbouncer/pgbouncer.ini` et `userlist.txt` (générés par Ansible). Toutes les bases pointent vers `keepalived_vip:haproxy_pg_rw_port`. Mode de pool `transaction` (`pgbouncer_pool_mode`), `auth_type = scram-sha-256`.
- **Comptes** : seuls ceux de `pgbouncer_users` (par défaut `pg_console_user`) peuvent se connecter via PgBouncer, avec leur mot de passe en clair dans `userlist.txt`. Ajouter les comptes applicatifs à cette liste, puis rejouer le rôle. À protéger par `ansible-vault`.
- Les IP des 3 nœuds et la VIP sont ajoutées à `haproxy_allowed_sources`, car PgBouncer joint HAProxy depuis le nœud.
- En mode `transaction`, les fonctions liées à la session (`SET`, requêtes préparées côté serveur, `LISTEN`, verrous de session) ne sont pas fiables : passer en `session` si une application en dépend.
- Console PgBouncer : `psql -h <VIP> -p 6432 -U <pg_console_user> pgbouncer -c "SHOW POOLS;"`.
- Image : `edoburu/pgbouncer:latest` (`pgbouncer_image`), tirée via le proxy ; à figer sur un tag précis.

## Mise à jour de Docker (`upgrade-docker.yml`)

Aligne la version du moteur sur tous les nœuds déjà déployés (par exemple un nœud en `docker.io` Debian 26.x et un autre en Docker CE 29.x).

```bash
ansible-playbook upgrade-docker.yml --check --diff                 # simulation
ansible-playbook upgrade-docker.yml --limit SRV-DOCK2              # un premier nœud en test
ansible-playbook upgrade-docker.yml                                # tous les nœuds
ansible-playbook upgrade-docker.yml -e docker_target_version=29.9.3
```

Pour chaque nœud, un à la fois (`serial: 1`, le quorum Raft 2/3 est conservé), le playbook :
1. saute le nœud s'il est déjà à la version cible ;
2. le passe en `drain` et attend 30 s ;
3. ajoute le dépôt officiel Docker et retire `docker.io`, `containerd`, `runc` (Debian) ;
4. installe Docker CE à `docker_target_version` et fige les paquets ;
5. attend que le nœud soit `ready`, le repasse en `active`, attend 60 s, puis contrôle la version finale.

Les conteneurs du nœud redémarrent. Patroni gère le failover PostgreSQL, mais les services épinglés sur un nœud (etcd, Patroni) sont arrêtés pendant l'opération : à faire hors production, et vérifier `patronictl list` et `etcdctl endpoint health --cluster` avant de passer au nœud suivant. Vérifier aussi la disponibilité de la version avec `apt-cache madison docker-ce`.

## Commandes etcd

Alias, à lancer sur le nœud qui héberge un conteneur etcd :

```bash
E="docker exec $(docker ps -q -f name=pginfra_etcd | head -n1) etcdctl --endpoints=http://etcd1:2379"
$E endpoint health --cluster
$E endpoint status --cluster -w table       # leader, version, taille de la base
$E member list -w table
$E get /db --prefix --keys-only             # clés Patroni (namespace /db/)
$E alarm list
$E defrag --cluster
$E snapshot save /tmp/etcd.db               # sauvegarde, puis docker cp
docker service logs -f --tail 100 pginfra_etcd1
docker service update --force pginfra_etcd2 # redémarre un membre (un seul à la fois)
```

Ne jamais arrêter 2 membres sur 3 : le cluster perd son quorum et Patroni passe PostgreSQL en lecture seule.

## Vérifications après déploiement

Sur SRV-DOCK1 :

```bash
docker node ls                           # 3 nœuds Ready
docker stack services pginfra            # etcd1/2/3 en 1/1
docker stack services ptinfra            # patroni1/2/3 en 1/1
docker exec -it $(docker ps -q -f name=ptinfra_patroni1) \
  patronictl -c /etc/patroni/patroni.yml list
```

Résultat attendu : 1 Leader et 2 Sync Standby. Le premier démarrage peut durer une à deux minutes.

Portainer : `https://ip_node:9443`.

HAProxy et VIP (sur n'importe quel nœud) :

```bash
ip -4 addr show | grep <VIP>                     # la VIP est sur un seul nœud (DOCK1 normalement)
docker logs keepalived --tail 20                 # état MASTER/BACKUP
psql -h <VIP> -p 5010 -U postgres -c "select pg_is_in_recovery();"   # f = leader
psql -h <VIP> -p 5011 -U postgres -c "select pg_is_in_recovery();"   # t = réplica
```

## Dépannage

- **Versions Docker différentes entre nœuds** (visibles dans Portainer ou `docker node ls`) : lancer `upgrade-docker.yml`.
- **Échec au pull d'une image** : vérifier les variables proxy et `systemctl show docker --property=Environment`.
- **`bind source path does not exist`** : le play `node_prepare` n'a pas tourné sur ce nœud, ou le `node_id` est faux.
- **Un manager ne rejoint pas** : ouvrir entre les nœuds les ports 2377/tcp, 7946/tcp+udp et 4789/udp (non gérés par le playbook).
- **etcd jamais sain** : les 3 nœuds doivent être dans le swarm (quorum 2 sur 3). En cas d'anciennes données dans `/srv/docker/etcdN`, les supprimer.
- **Patroni ne démarre pas** : consulter `docker service logs ptinfra_patroni1`. En cas d'anciennes données dans `/srv/docker/postgresN`, les supprimer et relancer.
- **La VIP n'apparaît pas** : vérifier `keepalived_vip` et `keepalived_interface`, ouvrir le protocole VRRP (protocole IP 112) entre les nœuds, et lire `docker logs keepalived`.
- **La VIP reste sur un nœud sans HAProxy** : contrôler que le conteneur `haproxy` tourne (`docker ps`) et que le port 8404 répond.
- **HAProxy marque tous les serveurs DOWN** : tester `curl http://<ip nœud>:8008/primary` depuis le nœud ; le port 8008 doit être publié par la stack `ptinfra`.
- **`no pg_hba.conf entry` sur le port 5010** : sur un cluster déjà initialisé, les règles du `pg_hba` ajoutées plus tard ne sont pas appliquées (voir Points d'attention).
- **Rejouer après un essai raté** : supprimer les stacks (`docker stack rm ptinfra pginfra`), vider `/srv/docker/etcdN` et `/srv/docker/postgresN` sur les 3 nœuds, puis relancer le playbook.

## Points d'attention

- Le pare-feu n'est pas géré par le playbook : ports Swarm, protocole VRRP (112) entre les nœuds, ports 5010, 5011 et 8404 vers les clients.
- La section `bootstrap` de Patroni (dont `pg_hba`) n'est lue qu'à la première initialisation du cluster. Sur un cluster existant, les nouvelles règles `pg_hba` (nœuds, `docker_gwbridge`) doivent être ajoutées avec `patronictl edit-config` ou en réinitialisant le cluster.
- L'API REST Patroni (port 8008) est accessible en lecture depuis le réseau ; seules les modifications exigent le compte `patroni_api_user`.
- Les mots de passe sont en clair dans `vars.yml` et le `pg_hba` contient des règles `trust` : à revoir avant la production.
- Le token etcd est `TEST-CLUSTER` dans `etcd-stack.yml` : à changer pour un environnement de production.
- `stack.yml` (nginx) et le dossier `_old/` ne sont pas utilisés.
