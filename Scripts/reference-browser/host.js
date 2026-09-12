const parameters = new URLSearchParams(location.search);
const dimension = (name,fallback) => {
  const value = Number(parameters.get(name));
  return Number.isFinite(value) && value > 0 ? value : fallback;
};
const viewport = document.querySelector('#viewport');
const width = dimension('width',402), height = dimension('height',700);
viewport.style.width = width+'px'; viewport.style.height = height+'px';
document.querySelector('#tools').style.left = (width+24)+'px';
viewport.src = 'frame.html'+location.search;
