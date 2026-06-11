#!/opt/homebrew/bin/zsh

echo 'Updating conda & mamba...'
echo ' '

conda update conda --solver=classic
conda update mamba --solver=classic

echo ' '
echo 'Updating complete!'
echo ' '