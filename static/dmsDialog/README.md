# dmsDialog.js
Javascript alert/confirm dialog replacement

# Instructions
Load the script into your HTML document:

    <script type="text/javascript" src="dmsDialog.js"></script>

To present an alert dialog, call the javascript function:

    dmsDialog.alert("Message!");

To present a confirm dialog, call the javascript function:

    dmsDialog.confirm("Are you sure?", function(){
      // This function is called if the user presses OK
    });

No function is executed if the user presses Cancel, similar to alert().

Instead of a single string for a message, you may pass an array.
Elements will be wrapped in HTML 'p' tags.

The message string or array of strings can contain arbitrary HTML, such
as an input checkbox or text input.
