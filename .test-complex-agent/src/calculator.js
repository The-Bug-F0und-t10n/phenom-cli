/**
 * Módulo Calculator - Operações matemáticas básicas
 */

/**
 * Soma dois números
 * @param {number} a - Primeiro número
 * @param {number} b - Segundo número
 * @returns {number} Resultado da soma
 */
function sum(a, b) {
    return a + b;
}

/**
 * Subtrai o segundo número do primeiro
 * @param {number} a - Primeiro número
 * @param {number} b - Segundo número
 * @returns {number} Resultado da subtração
 */
function subtract(a, b) {
    return a - b;
}

/**
 * Multiplica dois números
 * @param {number} a - Primeiro número
 * @param {number} b - Segundo número
 * @returns {number} Resultado da multiplicação
 */
function multiply(a, b) {
    return a * b;
}

/**
 * Divide o primeiro número pelo segundo
 * @param {number} a - Numerador
 * @param {number} b - Denominador
 * @returns {number} Resultado da divisão
 * @throws {Error} Se o denominador for zero
 */
function divide(a, b) {
    if (b === 0) {
        throw new Error("Divisão por zero não é permitida!");
    }
    return a / b;
}

module.exports = {
    sum,
    subtract,
    multiply,
    divide
};
