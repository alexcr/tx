#!/bin/sh
set -e

# Parse flags
BUMP="patch"
for arg in "$@"; do
    case "$arg" in
        --major) BUMP="major" ;;
        --minor) BUMP="minor" ;;
        --patch) BUMP="patch" ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# 1. Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: uncommitted changes. Commit or stash before publishing." >&2
    exit 1
fi

# Check for untracked files
if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "Error: untracked files present. Commit or remove before publishing." >&2
    exit 1
fi

# Check for unpushed commits
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ -n "$(git log origin/$BRANCH..HEAD 2>/dev/null)" ]; then
    echo "Error: unpushed commits on $BRANCH. Push before publishing." >&2
    exit 1
fi

# 2. Bump version (skip if last commit was already a version bump)
LAST_MSG=$(git log -1 --format=%s)
VERSION=$(grep '"version"' package.json | sed 's/.*: *"\([^"]*\)".*/\1/')

if echo "$LAST_MSG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Last commit is already a version bump ($LAST_MSG). Skipping to publish."
    NEW_VERSION="$VERSION"
else
    IFS='.' read -r MAJOR MINOR PATCH <<EOF
$VERSION
EOF

    case "$BUMP" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac

    NEW_VERSION="$MAJOR.$MINOR.$PATCH"
    echo "Bumping version: $VERSION -> $NEW_VERSION ($BUMP)"

    # Update package.json
    sed -i '' "s/\"version\": \"$VERSION\"/\"version\": \"$NEW_VERSION\"/" package.json

    # 3. Commit the version change
    git add package.json
    git commit -m "v$NEW_VERSION"

    # 4. Push to origin
    git push origin "$BRANCH"
fi

# 5. Publish
npm publish

echo "Published v$NEW_VERSION"
