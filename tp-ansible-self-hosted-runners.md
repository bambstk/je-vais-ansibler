# TP — Runners self-hosted (GitHub & GitLab) provisionnés par Terraform et configurés par Ansible

## Objectifs pédagogiques

À la fin de ce TP, vous saurez :
- Expliquer ce qu'est Ansible et en quoi il diffère de Terraform.
- Expliquer le principe d'un runner CI/CD self-hosted (GitHub Actions et GitLab CI).
- Provisionner une VM avec Terraform, puis la configurer avec Ansible pour en faire un runner.
- Enregistrer ce runner sur un repo GitHub **et** sur un projet GitLab.
- Basculer une pipeline CI existante sur ce runner et mesurer le gain (cache persistant).

**Contrainte du TP : tout le pipeline CI/CD doit s'exécuter entièrement depuis GitHub Actions et/ou
GitLab CI — aucune commande `terraform apply`/`ansible-playbook` ne doit être lancée à la main
depuis votre poste en dehors de la phase de mise au point initiale.** L'objectif est un pipeline
reproductible, pas une suite de commandes manuelles.

---

## Partie 0 — Rappels théoriques

### Qu'est-ce qu'Ansible ?

Ansible est un outil de **gestion de configuration** (Configuration Management) : il installe des
paquets, modifie des fichiers de config, démarre des services, etc. **sur des machines qui existent
déjà**. C'est complémentaire à Terraform, pas concurrent :

| | Terraform | Ansible |
|---|---|---|
| Rôle | Provisionner l'infrastructure (créer une VM, un réseau, une base de données…) | Configurer ce qui tourne **sur** une machine déjà créée |
| Modèle | Déclaratif, état géré (state file) | Impératif par tâches, mais conçu pour être **idempotent** (relancer un playbook ne doit rien casser si rien n'a changé) |
| Cible typique | Ressources cloud (API Azure/AWS/GCP) | Serveurs (SSH), conteneurs, équipements réseau |

Un **playbook** Ansible est une liste de tâches YAML. Les tâches sont regroupées en **rôles**
(dossiers réutilisables : `tasks/`, `defaults/`, `handlers/`…). Ansible se connecte aux machines
cibles en SSH (pas d'agent à installer sur la cible, contrairement à Puppet/Chef) et n'a besoin
d'aucun état persistant de son côté — c'est la machine cible elle-même qui reflète l'état désiré.

### Pourquoi un runner self-hosted ?

GitHub Actions et GitLab CI fournissent par défaut des machines **hébergées** (`ubuntu-latest` côté
GitHub, les "shared runners" côté GitLab) : gratuites dans une certaine limite, mais :
- **Éphémères** : chaque run repart d'une machine vierge → aucun cache entre deux builds (toutes les
  dépendances sont retéléchargées à chaque fois).
- **Limitées en quota** : minutes gratuites limitées par mois (particulièrement restrictif sur
  Bitbucket Cloud : 50 min/mois sur le plan gratuit).
- **Spec fixes** : pas de contrôle sur le CPU/RAM/disque alloué.

Un runner **self-hosted** est une machine que **vous** fournissez (VM, conteneur, poste physique) et
sur laquelle vous installez un agent (`actions-runner` côté GitHub, `gitlab-runner` côté GitLab) qui
vient "s'enregistrer" auprès de la plateforme et attend qu'on lui envoie des jobs. Avantages :
persistance du cache entre les runs, aucune limite de minutes, contrôle total des specs — au prix de
devoir maintenir la machine soi-même (mises à jour, sécurité, disponibilité).

**Différence clé d'enregistrement** :
- **GitHub** : le runner s'enregistre via un **token d'enregistrement à courte durée de vie** (1h),
  obtenu via l'API GitHub (`POST /repos/{owner}/{repo}/actions/runners/registration-token`), avec un
  PAT ayant la permission `Administration: read/write` sur le repo cible.
- **GitLab** : le runner s'enregistre via `gitlab-runner register` avec un token d'enregistrement
  récupéré dans Settings → CI/CD → Runners du projet (mécanisme plus simple, pas d'appel API à
  orchestrer soi-même).

### Sécurité : pourquoi c'est plus délicat qu'il n'y paraît

Un self-hosted runner sur un **repo public** est un vecteur d'exécution de code arbitraire si
quelqu'un d'externe peut déclencher un workflow dessus (ex: une pull request depuis un fork). Ne
faites ça que sur des repos privés, ou si vous contrôlez strictement qui peut ouvrir des PR.

---

## Partie 1 — Provisionner la VM avec Terraform

1. Dans votre repo Terraform, créez un nouveau répertoire dédié (état séparé du reste de l'infra —
   cette VM a un cycle de vie indépendant).
2. Ressources nécessaires : `azurerm_subnet` (son propre sous-réseau, pour ne pas mélanger des
   règles NSG inline avec des règles standalone sur le même NSG existant), `azurerm_network_security_group`
   (SSH restreint à **votre propre IP publique** en `/32`), `azurerm_public_ip`, `azurerm_network_interface`,
   `tls_private_key` (Terraform génère la paire de clés SSH pour vous), `azurerm_linux_virtual_machine`
   (Ubuntu 22.04, taille `Standard_B2s` pour commencer).
3. Exposez en `output` (le second marqué `sensitive = true`) : l'IP publique de la VM et la clé SSH
   privée générée.
4. **Piège à connaître** : les tailles de VM B-series (burstable, moins chères) sont parfois
   indisponibles par manque de capacité selon la région/l'abonnement Azure. Si `terraform apply`
   échoue avec une erreur de capacité, basculez sur `Standard_D2s_v3`.
5. Appliquez via votre pipeline CI existante (`workflow_dispatch`), jamais en local à la main.

### Récupérer la clé SSH privée sans jamais la faire transiter en clair

La sortie `terraform output` d'une valeur `sensitive` s'affiche masquée (`<sensitive>`) par défaut.
Utilisez le flag `-raw`, qui affiche/exporte la vraie valeur même pour un output sensible :

```bash
terraform output -raw ma_cle_privee_ssh | gh secret set NOM_DU_SECRET --repo owner/repo
```

**Ne collez jamais une clé privée, un token ou tout autre secret directement dans un chat, un
ticket, ou un fichier versionné — même "juste pour vérifier".** Une fois écrit quelque part de
persistant, considérez-le compromis et régénérez-le.

---

## Partie 2 — Le repo de configuration Ansible

Créez un repo séparé (Terraform provisionne, Ansible configure — deux responsabilités, deux repos).

Structure minimale :
```
ansible.cfg
playbook.yml
roles/
  mon_role/
    defaults/main.yml   # variables par défaut du rôle
    tasks/main.yml       # les tâches
```

### `ansible.cfg`

```ini
[defaults]
host_key_checking = True
retry_files_enabled = False
interpreter_python = auto_silent
```

**Piège** : `host_key_checking = True` est la bonne pratique de sécurité (protège contre un
détournement de l'hôte en cours de session), mais un runner GitHub/GitLab hébergé démarre une
machine **vierge à chaque run** — il n'y a jamais de `known_hosts` pré-rempli. Il faut donc épingler
la clé de l'hôte **au début de chaque run**, pas la désactiver globalement :

```bash
ssh-keyscan -H "$IP_DE_LA_VM" >> ~/.ssh/known_hosts
```

### `playbook.yml`

```yaml
---
- name: Configurer le runner
  hosts: all
  become: true
  roles:
    - mon_role
```

**Piège** : ne mettez pas `hosts: runner` en pensant que ça matche un "groupe logique" — si vous
passez l'inventaire à la volée (`-i "IP,"`, une seule IP suivie d'une virgule), l'hôte atterrit dans
le groupe implicite `ungrouped`, pas dans un groupe nommé "runner". Utilisez `hosts: all`.

### Conventions de nommage des variables (`ansible-lint`)

Si vous utilisez `ansible-lint` (recommandé), son profil de base exige que **toute variable définie
à l'intérieur d'un rôle** (via `register:`, `set_fact:`, ou dans `defaults/main.yml`) soit préfixée
par le nom du rôle — ex. pour un rôle `mon_role`, une variable doit s'appeler `mon_role_xxx`, pas
`xxx` tout court.

### Autres règles `ansible-lint` fréquemment déclenchées

- **`no-changed-when`** : un module `command`/`shell` ne sait pas dire tout seul s'il a "changé"
  quelque chose — ajoutez `changed_when: true` (ou une condition plus fine) explicitement.
- **`partial-become`** : si vous mettez `become_user: quelquun` sur une tâche, mettez aussi
  `become: true` explicitement sur cette même tâche, même si le play entier a déjà `become: true`.
- **`name[template]`** : n'utilisez pas de variable Jinja (`{{ ... }}`) au milieu d'un nom de tâche
  — seulement à la toute fin, ou pas du tout.

### Piège supplémentaire : une VM nue n'a presque aucun outil pré-installé

Les runners **hébergés** (`ubuntu-latest`) embarquent gratuitement des dizaines d'outils préinstallés
(`unzip`, `git`, `jq`, le CLI Azure, Node.js récent, Docker, etc.). Une VM Ubuntu fraîchement
provisionnée par Terraform n'a **rien de tout ça** — vous découvrirez les manques un par un, au fil
des jobs CI qui échoueront dessus, chacun avec une erreur différente :
- `Unable to locate executable file: unzip` — beaucoup d'actions (dont celles qui installent des CLI
  comme Terraform) extraient une archive `.zip`.
- Une action `checkout`/`setup-*` qui échoue silencieusement ou en profondeur si `git` n'est pas là.
- `Unable to locate executable file: az` — si votre pipeline s'authentifie sur Azure
  (`azure/login`), le CLI doit être installé à la main sur la VM (script officiel Microsoft :
  `curl -sL https://aka.ms/InstallAzureCLIDeb | bash`).
- `env: node: No such file or directory`, voire un `SyntaxError` cryptique si un `node` **trop
  ancien** est déjà présent — le paquet `nodejs` d'Ubuntu 22.04 via apt est une version 12, gelée
  dans les dépôts, alors que certaines actions embarquent du JavaScript moderne. Installez une
  version récente et **encore maintenue (LTS)** via le dépôt NodeSource
  (`https://deb.nodesource.com/setup_XX.x`) — vérifiez sur https://nodejs.org/en/about/previous-releases
  quelle version majeure est actuellement LTS avant de figer un numéro dans votre rôle : une LTS a
  une date de fin de vie, et un tutoriel qui code en dur "20.x" finira par recommander une version
  obsolète.

**Ne devinez pas la liste à l'avance** : le moyen le plus fiable de la découvrir est de lancer votre
vraie pipeline dessus et de corriger les échecs un par un, en ajoutant chaque paquet manquant à la
liste `Install base packages` de votre rôle. C'est normal et attendu — documentez ces allers-retours
dans votre compte-rendu, ils font partie du travail réel d'un runner self-hosted.

---

## Partie 3 — Le vrai piège du TP : la VM n'accepte SSH que depuis VOTRE IP

Votre NSG (Partie 1) n'autorise le SSH que depuis votre IP personnelle. Mais le pipeline CI qui va
exécuter `ansible-playbook` tourne sur une machine **hébergée par GitHub/GitLab**, avec une IP
totalement différente de la vôtre. Le job échouera avec un timeout de connexion.

**Deux solutions, une seule est acceptable pour ce TP (contrainte "tout dans GitHub/GitLab")** :

1. ❌ Lancer `ansible-playbook` depuis votre poste (votre IP est autorisée) — fonctionne, mais viole
   la contrainte du TP.
2. ✅ Faire en sorte que le **pipeline lui-même** ouvre temporairement la NSG pour sa propre IP,
   exécute Ansible, puis la referme — entièrement automatisé, jamais de commande manuelle.

Pour la solution 2, votre pipeline doit :
1. S'authentifier auprès d'Azure via **OIDC** (Workload Identity Federation) — pas de mot de passe
   ni de clé stockée en dur.
2. Déterminer sa propre IP publique (`curl -s https://api.ipify.org`).
3. Ajouter une règle NSG temporaire pour cette IP (`az network nsg rule create`), avec une priorité
   différente de la règle permanente.
4. Exécuter le playbook.
5. Supprimer la règle temporaire (`az network nsg rule delete`), **avec `if: always()`** pour que ça
   se nettoie même si le playbook a échoué en cours de route — ne laissez jamais une règle de
   pare-feu temporaire orpheline.

### Authentification OIDC : le piège du "subject" qui diffère selon l'ancienneté du repo

Pour configurer la fédération d'identité (`az ad app federated-credential create`), le `subject`
attendu par Azure doit correspondre **exactement** à ce que GitHub envoie dans le token OIDC. Sur
des repos créés récemment, GitHub peut inclure les **identifiants numériques immuables** du compte
et du repo dans le subject :

```
repo:MONCOMPTE@ID_COMPTE/MONREPO@ID_REPO:ref:refs/heads/main
```

...alors qu'un repo plus ancien peut utiliser le format "classique" :

```
repo:MONCOMPTE/MONREPO:ref:refs/heads/main
```

**Si la fédération échoue avec `AADSTS700213: No matching federated identity record found`, le
message d'erreur contient le `subject` exact que GitHub a réellement envoyé** — copiez-le tel quel
dans votre `az ad app federated-credential create`/`update`, ne devinez pas le format à l'avance.

---

## Partie 4 — Enregistrer le runner

### Côté GitHub

Dans le playbook (ou un script appelé par lui), récupérez un token d'enregistrement **frais** à
chaque run (il expire au bout d'1h, impossible de le pré-générer à l'avance) :

```bash
curl -X POST \
  -H "Authorization: Bearer $GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/OWNER/REPO/actions/runners/registration-token
```

Puis sur la VM cible :
```bash
./config.sh --url https://github.com/OWNER/REPO --token LE_TOKEN --unattended
./svc.sh install
./svc.sh start
```

`GITHUB_PAT` doit être un PAT **fine-grained**, scopé uniquement au repo cible, avec la permission
**Administration: Read and write** — rien de plus large.

### Côté GitLab

Plus simple : récupérez le token d'enregistrement dans Settings → CI/CD → Runners du projet, puis
sur la VM :
```bash
gitlab-runner register --url https://gitlab.com/ --token LE_TOKEN --executor shell
gitlab-runner start
```

### Vérification

```bash
gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | {name, status, busy}'
```
Le runner doit apparaître `"status": "online"`.

---

## Partie 5 — Basculer une pipeline sur le runner

Dans un workflow GitHub Actions existant, remplacez :
```yaml
runs-on: ubuntu-latest
```
par :
```yaml
runs-on: [self-hosted, linux, x64]
```
(utilisez la liste complète des labels, pas juste `self-hosted` seul, dès que vous avez plusieurs
runners aux specs différentes — sinon GitHub peut assigner le job à n'importe lequel).

**Ne modifiez pas directement votre pipeline de production** : dupliquez-la d'abord
(`workflow_dispatch` uniquement, pas encore "required check") pour comparer les temps d'exécution
avant de basculer définitivement.

### Ce que vous devriez observer

- **1er run sur le self-hosted** : temps comparable au runner hébergé (cache vide, comme sur une
  machine neuve).
- **2e run** : nettement plus rapide (le cache des dépendances — `~/.m2` pour Maven, `node_modules`/
  cache npm pour Node, etc. — persiste sur la VM entre deux runs, contrairement au runner hébergé qui
  repart de zéro à chaque fois).

Mesurez et documentez cet écart dans votre rendu.

### Et si votre pipeline est du Terraform (apply/destroy) plutôt qu'un build applicatif ?

Refaites la même comparaison hosted vs self-hosted, mais cette fois sur un `terraform apply` puis
`terraform destroy` d'une vraie ressource (une base managée, un service applicatif — pas juste un
`terraform plan` qui ne modifie rien). Vous aurez besoin d'une **seconde instance de runner** sur la
même VM si ce pipeline vit dans un repo différent de celui déjà utilisé en Partie 5 (voir "Pour aller
plus loin" ci-dessous — un compte GitHub personnel enregistre un runner par repo, pas par compte).

**Ce que vous devriez observer cette fois : l'écart hosted/self-hosted est nul, voire inversé** —
contrairement au cas Maven/npm. Pourquoi :
- Le temps est dominé par le **provisioning côté cloud** (une base de données ou un cache managé
  peut prendre 5 à 10 minutes à être créé côté Azure/AWS/GCP), identique quelle que soit la machine
  qui lance `terraform apply` — Terraform ne fait qu'attendre en interrogeant l'API du fournisseur.
- `terraform init` télécharge quelques dizaines de Mo de plugins, sans commune mesure avec les
  centaines de dépendances d'un projet Maven/npm — un cache local n'a presque rien à apporter.
- La VM self-hosted, si elle est dimensionnée petit (`Standard_B2s` par ex.), peut même être plus
  lente en CPU/réseau que le runner hébergé, ce qui peut annuler le peu de gain restant.

**Conclusion à documenter dans votre rendu** : le gain d'un runner self-hosted dépend de la nature du
goulot d'étranglement de votre pipeline — mesurez avant de généraliser à partir d'un seul type de job.
Ne présumez pas qu'un self-hosted est toujours plus rapide.

---

## Livrables attendus

1. Le code Terraform de provisioning de la VM (repo dédié ou dossier séparé).
2. Le repo Ansible (playbook + rôle) qui configure la VM.
3. Le pipeline CI/CD (GitHub Actions et/ou GitLab CI) qui orchestre l'ouverture temporaire du
   pare-feu + l'exécution du playbook — **aucune étape manuelle**.
4. Un court compte-rendu (README ou document séparé) qui documente : les pièges rencontrés, les
   temps de build hosted vs self-hosted, et une capture d'écran du runner "online" sur GitHub et/ou
   GitLab.

## Pour aller plus loin (optionnel)

- Automatiser le chaînage Terraform → Ansible (déclenchement automatique du playbook juste après
  l'apply, sans étape manuelle entre les deux).
- Ajouter un second runner (GitLab, ou un second runner GitHub pour un autre repo) sur la même VM,
  avec des labels/répertoires d'installation différents.
  **Piège d'idempotence à connaître** : si votre tâche d'installation du service systemd utilise un
  `creates:` du type `/etc/systemd/system/actions.runner.*.service` pour éviter de la relancer
  inutilement, ce glob matche **n'importe quelle** instance déjà installée sur la VM, pas seulement
  celle en cours de configuration. Résultat : la deuxième instance semble "déjà configurée" et son
  service n'est jamais réellement installé. Rendez la condition d'idempotence spécifique à
  l'instance (nom exact du fichier de service attendu, calculé à partir du repo cible et du nom du
  runner), pas un motif générique.
- Mettre en place une politique de mise à jour automatique de l'OS (`unattended-upgrades`) et un
  pare-feu applicatif (`ufw`/`fail2ban`) sur la VM — un runner self-hosted est une machine exposée
  en continu, elle mérite le même niveau de durcissement qu'un serveur de production.
