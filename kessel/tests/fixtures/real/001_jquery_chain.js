// jQuery-style chainable calls
$(document).ready(function() {
  $('#myDiv')
    .addClass('active')
    .removeClass('hidden')
    .css('color', 'red')
    .fadeIn(300)
    .on('click', function(e) {
      e.preventDefault();
      $(this).toggleClass('selected');
    });
});
