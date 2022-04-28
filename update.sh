#!/opt/homebrew/bin/zsh

echo 'Apps to update'
brew outdated
brew outdated --cask
mas outdated

echo 'Updating Applications...'
    brew upgrade
    brew update # Updating home-brew apps & formulas
    brew upgrade --cask # Updating apps installed as casks
    mas upgrade # Updating Mac App Store apps
echo 'Cleaning caches & directories...'
    brew cleanup -s # Clearing home-brew cache
echo 'Updating Complete!'
