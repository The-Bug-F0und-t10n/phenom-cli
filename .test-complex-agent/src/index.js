/**
 * Main entry point - exports all calculator functions
 */

// Import the calculator functions
const { sum, subtract, multiply, divide } = require('./calculator');

// Re-export all functions for convenient import
module.exports = {
  sum,
  subtract,
  multiply,
  divide
};
