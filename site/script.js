const menuButton = document.querySelector('.menu-button');
const navLinks = document.querySelector('.nav-links');

menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
  menuButton.setAttribute('aria-expanded', String(!isOpen));
  navLinks.classList.toggle('open', !isOpen);
});

navLinks?.addEventListener('click', event => {
  if (event.target.closest('a')) {
    menuButton?.setAttribute('aria-expanded', 'false');
    navLinks.classList.remove('open');
  }
});

const copyButton = document.querySelector('.copy-button');
const copyStatus = document.querySelector('.copy-status');

copyButton?.addEventListener('click', async () => {
  const target = document.getElementById(copyButton.dataset.copyTarget);
  try {
    await navigator.clipboard.writeText(target.innerText);
    copyButton.textContent = 'Copied';
    copyStatus.textContent = 'Homebrew commands copied to the clipboard.';
  } catch {
    copyStatus.textContent = 'Copy failed. Select the commands and copy them manually.';
  }
});
