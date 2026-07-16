// Calculator JavaScript
let display = document.getElementById('display');

// Append value to display
function appendToDisplay(value) {
    display.value += value;
}

// Clear display
function clearDisplay() {
    display.value = '';
}

// Delete last character
function deleteLast() {
    display.value = display.value.slice(0, -1);
}

// Calculate result
function calculate() {
    try {
        // Evaluate the mathematical expression safely
        let result = eval(display.value);
        display.value = result;
    } catch (error) {
        display.value = 'Error';
        setTimeout(clearDisplay, 1500);
    }
}
