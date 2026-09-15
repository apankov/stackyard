#!/usr/bin/env bash

# Внешние реестры образов: логин, пин подвижного тега в digest, проверка.
#
# Смысл существования. Токен ECR живёт 12 часов, то есть `docker login` руками —
# это механизм со сроком годности, за которым надо следить, а забытый логин
# проявляется как отказ pull'а в момент деплоя. Поэтому логина «заранее» здесь
# нет вовсе: он вшит в тот путь, который единственный и тянет образы, —
# docker-compose.sh зовёт `registry.sh login --soft` перед командами, способными
# обратиться в реестр.
#
# Второе следствие того же: стек запускается от DIGEST'а, а не от подвижного
# тега. `:master` означает, что `up -d` берёт то, что уже лежит локально, и
# молча расходится с реестром, а откатиться некуда — предыдущего тега не
# существует. Digest в stacks/<стек>/.env отвечает на вопрос «что сейчас
# запущено» и даёт откат: вернуть прежнюю строку и `up -d`.
#
#   ./platform/bin/registry.sh login           логин во все реестры включённых стеков
#   ./platform/bin/registry.sh pin <стек>      Image_Tag -> digest в stacks/<стек>/.env
#   ./platform/bin/registry.sh --check         что не так, без изменений (код 1)
#
# Реестры, кроме ECR, скрипт логинить не умеет и говорит об этом вслух: у
# каждого своя команда выдачи пароля, и угадывать её тут нечем.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

problems=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; problems=$((problems + 1)); }
step() { echo; echo "== $1"; }

# Штамп последнего логина. В /tmp намеренно: это ровно эфемерное состояние —
# после перезагрузки лишний логин ничего не стоит, а пережить её штампу нечего.
# TTL меньше срока токена (12 ч) с запасом на долгий деплой.
STAMP_TTL=$((8 * 3600))
stamp_file() { printf '%s/devbox-registry-login-%s-%s' "${TMPDIR:-/tmp}" "$(id -u)" "${1//[^A-Za-z0-9._-]/_}"; }

# Регион ECR выводится из имени хоста (<id>.dkr.ecr.<регион>.amazonaws.com), а
# не объявляется отдельно: второе место с тем же знанием разъедется с образом.
ecr_region() {
  case "$1" in
    *.dkr.ecr.*.amazonaws.com) local r="${1#*.dkr.ecr.}"; printf '%s' "${r%.amazonaws.com}" ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------- login

# registry_login <хост> <мягко?>
registry_login() {
  local host="$1" soft="$2" region stamp
  stamp="$(stamp_file "$host")"

  if [ -f "$stamp" ] && [ $(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp") )) -lt "$STAMP_TTL" ]; then
    [ "$soft" -eq 1 ] || ok "$host — логин свежий (моложе $((STAMP_TTL / 3600)) ч)"
    return 0
  fi

  if ! region="$(ecr_region "$host")"; then
    if [ "$soft" -eq 1 ]; then
      echo "Предупреждение: $host — не ECR, логин этим скриптом не делается; залогиньтесь сами" >&2
    else
      bad "$host — не ECR: команда выдачи пароля у каждого реестра своя, залогиньтесь вручную"
    fi
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    if [ "$soft" -eq 1 ]; then
      echo "Предупреждение: нет команды aws — логин в $host не сделан, pull упадёт" >&2
      return 0
    fi
    bad "нет команды aws — логин в $host сделать нечем"
    return 1
  fi

  if aws ecr get-login-password --region "$region" 2>/dev/null \
     | docker login --username AWS --password-stdin "$host" >/dev/null 2>&1; then
    : > "$stamp"
    [ "$soft" -eq 1 ] || ok "$host — вход выполнен"
    return 0
  fi

  # Права машина берёт из IAM-роли инстанса; отвалившаяся роль выглядит точно
  # так же, как исправная, до первого обращения — поэтому причина называется
  # здесь, а не всплывает потом невнятной ошибкой pull'а.
  if [ "$soft" -eq 1 ]; then
    echo "Предупреждение: не удалось войти в $host (IAM-роль инстанса? ecr:GetAuthorizationToken?) — pull упадёт" >&2
    return 0
  fi
  bad "$host — вход не удался; проверьте IAM-роль инстанса и право ecr:GetAuthorizationToken"
  return 1
}

verb_login() {
  local soft=0 host any=0 hosts
  if [ "${1:-}" = "--soft" ]; then soft=1; fi
  # Разбиение на слова здесь намеренное: stacks_enabled отдаёт список стеков.
  # shellcheck disable=SC2046
  hosts="$(stacks_registries $(stacks_enabled 2>/dev/null) 2>/dev/null)"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    any=1
    registry_login "$host" "$soft" || true
  done <<< "$hosts"
  if [ "$any" -eq 0 ] && [ "$soft" -eq 0 ]; then
    ok "ни один включённый стек не тянет образы из внешнего реестра"
  fi
  if [ "$soft" -eq 1 ]; then return 0; fi
  return $(( problems > 0 ))
}

# ---------------------------------------------------------------- разбор

# Ссылка на образ стека во внешнем реестре — ровно одна на стек. Больше одной
# означало бы, что стек тянет два разных приложения, и pin не знал бы, какое
# из них он пинит; меньше — что пинить нечего.
stack_registry_image() {
  local imgs
  imgs="$(stack_registry_images "$1")"
  [ -n "$imgs" ] || return 1
  printf '%s' "$imgs" | head -n 1
}

# Имя переменной с digest'ом — из самой ссылки (`<репозиторий>@${ПЕРЕМЕННАЯ}`).
# Отдельного объявления нет намеренно: имя переменной уже написано в
# compose.yaml, и второе место с ним разъехалось бы молча.
image_digest_var() {
  case "$1" in
    *@\$\{*) local v="${1#*@\$\{}"; v="${v%%\}*}"; printf '%s' "${v%%:*}" ;;
    *) return 1 ;;
  esac
}

image_repo_path() { local v="${1%%@*}"; v="${v%%:*}"; printf '%s' "${v#*/}"; }

# ---------------------------------------------------------------------- pin

verb_pin() {
  local s="${1:-}" img host region repo var tag digest envf cur tmp
  [ -n "$s" ] || { echo "Использование: $0 pin <стек>" >&2; exit 2; }
  stack_exists "$s" || { echo "Ошибка: нет стека '$s'" >&2; exit 2; }

  img="$(stack_registry_image "$s")" \
    || { echo "Ошибка: стек '$s' не тянет образ из внешнего реестра — пинить нечего" >&2; exit 2; }
  var="$(image_digest_var "$img")" \
    || { echo "Ошибка: образ стека '$s' задан не через digest ($img) — пин здесь ни при чём" >&2; exit 2; }
  tag="$(stack_image_tag "$s")"
  [ -n "$tag" ] || { echo "Ошибка: у стека '$s' не объявлен Image_Tag= в stack.conf — непонятно, за каким тегом следить" >&2; exit 2; }

  host="$(image_registry "$img")"
  region="$(ecr_region "$host")" \
    || { echo "Ошибка: $host — не ECR, резолвить тег в digest этим скриптом нечем" >&2; exit 2; }
  repo="$(image_repo_path "$img")"

  registry_login "$host" 0 >/dev/null || true

  digest="$(aws ecr describe-images --region "$region" --repository-name "$repo" \
              --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' \
              --output text 2>/dev/null || true)"
  case "$digest" in
    sha256:*) ;;
    *) echo "Ошибка: в $host/$repo нет образа с тегом '$tag' (или нет прав ecr:DescribeImages)" >&2; exit 1 ;;
  esac

  envf="$(stack_env_file "$s")"
  [ -f "$envf" ] || { echo "Ошибка: нет $envf — завести из образца" >&2; exit 2; }

  ENV_VARS=(); env_load_files "$envf" >/dev/null 2>&1 || true
  cur="$(env_get "$var")"
  if [ "$cur" = "$digest" ]; then
    echo "$s: уже на $digest (тег $tag) — менять нечего"
    return 0
  fi

  # Переписываем через временный файл и `cat > оригинал`: inode и права 600
  # сохраняются, а внутри .env пароли — потерять их на mv было бы дорого.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if grep -qE "^[[:space:]]*${var}=" "$envf"; then
    awk -v var="$var" -v val="$digest" '
      $0 ~ "^[[:space:]]*" var "=" { print var "=" val; next } { print }
    ' "$envf" > "$tmp"
  else
    { cat "$envf"; printf '%s=%s\n' "$var" "$digest"; } > "$tmp"
  fi
  cat "$tmp" > "$envf"

  echo "$s: $var"
  echo "  было:  ${cur:-<не задан>}"
  echo "  стало: $digest   (тег $tag)"
  echo
  echo "Применить: ./dc up -d $(stack_services "$s" | tr '\n' ' ')"
  echo "Откатить:  вернуть прежнюю строку в $envf и повторить up -d"
}

# -------------------------------------------------------------------- check

verb_check() {
  local host s img var tag region repo cur envf latest

  step "Реестры"
  if [ -z "$(stacks_registries)" ]; then
    ok "ни один стек не тянет образы из внешнего реестра — проверять нечего"
    return 0
  fi
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if ! region="$(ecr_region "$host")"; then
      warn "$host — не ECR: логин и пин делаются вручную, проверить их отсюда нечем"
      continue
    fi
    if ! command -v aws >/dev/null 2>&1; then
      bad "нет команды aws — ни логин, ни резолв тега в digest невозможны"
      continue
    fi
    # Единственный честный вопрос к правам: выдаётся ли токен ПРЯМО СЕЙЧАС.
    # Наличие IAM-роли, профиля и сети по отдельности ничего не гарантирует.
    if aws ecr get-authorization-token --region "$region" >/dev/null 2>&1; then
      ok "$host — токен выдаётся (регион $region)"
    else
      bad "$host — токен не выдаётся: IAM-роль инстанса и право ecr:GetAuthorizationToken"
    fi
  done < <(stacks_registries)

  step "Образы включённых стеков"
  local seen=0
  while IFS= read -r s; do
    img="$(stack_registry_image "$s")" || continue
    seen=$((seen + 1))
    host="$(image_registry "$img")"
    region="$(ecr_region "$host")" || { warn "$s: $host — не ECR, дальше не проверяю"; continue; }
    repo="$(image_repo_path "$img")"

    tag="$(stack_image_tag "$s")"
    [ -n "$tag" ] || bad "$s: нет Image_Tag= в stack.conf — registry.sh pin не знает, за каким тегом следить"

    if ! var="$(image_digest_var "$img")"; then
      warn "$s: образ задан тегом ($img), а не digest'ом — up -d возьмёт локальный слепок и разойдётся с реестром молча"
      continue
    fi

    envf="$(stack_env_file "$s")"
    # ENV_VARS объявлен в lib-env.sh и наполняется загрузчиком; чистим его
    # перед каждым стеком, иначе значения предыдущего утекут в следующий.
    # shellcheck disable=SC2034
    ENV_VARS=(); env_load_files "$envf" >/dev/null 2>&1 || true
    cur="$(env_get "$var")"
    case "$cur" in
      sha256:*) ;;
      '') bad "$s: в $(basename "$(dirname "$envf")")/.env не задан $var — compose не соберётся; ./platform/bin/registry.sh pin $s"; continue ;;
      *)  bad "$s: $var=$cur не похож на digest (ожидается sha256:...)"; continue ;;
    esac

    command -v aws >/dev/null 2>&1 || continue

    # Запинненный digest мог исчезнуть из реестра по retention policy. Пока
    # образ лежит локально, это никак не видно — и проявится ровно тогда, когда
    # контейнер придётся пересоздать, то есть в худший момент.
    if aws ecr describe-images --region "$region" --repository-name "$repo" \
         --image-ids "imageDigest=$cur" >/dev/null 2>&1; then
      ok "$s: запинненный образ в реестре есть"
    else
      bad "$s: образа $cur в $host/$repo больше нет — пересоздать контейнер будет нечем; ./platform/bin/registry.sh pin $s"
    fi

    if docker image inspect "${img%%@*}@$cur" >/dev/null 2>&1; then
      ok "$s: образ есть локально"
    else
      warn "$s: образа нет локально — ближайший up -d полезет в реестр"
    fi

    [ -n "$tag" ] || continue
    latest="$(aws ecr describe-images --region "$region" --repository-name "$repo" \
                --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' \
                --output text 2>/dev/null || true)"
    case "$latest" in
      sha256:*)
        if [ "$latest" = "$cur" ]; then
          ok "$s: запинненное совпадает с тегом '$tag'"
        else
          warn "$s: в реестре под тегом '$tag' лежит другой образ — ./platform/bin/registry.sh pin $s"
        fi ;;
      *) warn "$s: тега '$tag' в $host/$repo нет — следить не за чем" ;;
    esac
  done < <(stacks_enabled 2>/dev/null)
  # Ноль стеков — это не «всё хорошо», а «смотреть было не на что»: на машине
  # без .env-stacks включённым не считается никто, и молчание здесь читалось бы
  # как исправность.
  if [ "$seen" -eq 0 ]; then
    warn "ни один ВКЛЮЧЁННЫЙ стек не тянет образы из внешнего реестра — проверять было нечего"
  fi

  echo
  if [ "$problems" -eq 0 ]; then echo "Реестры: проблем нет"; else echo "Реестры: проблем — $problems"; fi
  return $(( problems > 0 ))
}

case "${1:-}" in
  login)   shift; verb_login "$@" ;;
  pin)     shift; verb_pin "$@" ;;
  --check) verb_check ;;
  ""|-h|--help)
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 2 ;;
  *) echo "Неизвестная команда: $1" >&2; exit 2 ;;
esac
