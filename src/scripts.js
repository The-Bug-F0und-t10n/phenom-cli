// scripts.js

// Example script to add interactivity to the cat gallery

document.addEventListener('DOMContentLoaded', function() {
  const catImages = document.querySelectorAll('.cat-image');

  catImages.forEach(image => {
    image.addEventListener('click', function() {
      this.classList.toggle('active');
    });
  });
});