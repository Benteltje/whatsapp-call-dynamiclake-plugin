// Run the bundled browser scripts against fixture controls, never a browser tab.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(`${__dirname}/../Sources/WhatsAppCallPlugin.swift`, 'utf8');
function script(name) {
    const match = source.match(new RegExp(`private let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`));
    assert(match, `missing ${name}`);
    return match[1];
}
let clicked = [];
function button(label, {pressed = null, ancestorPressed = null, hidden = false} = {}) {
    return {
        innerText: '', hidden,
        getAttribute: name => name === 'aria-label' ? label : name === 'aria-pressed' ? pressed : null,
        closest: () => ancestorPressed === null ? null : {getAttribute: () => ancestorPressed},
        getBoundingClientRect: () => ({width: hidden ? 0 : 20, height: 20}),
        click: () => clicked.push(label)
    };
}
function run(name, buttons, control, host = 'web.whatsapp.com') {
    const context = {
        location: {hostname: host},
        document: {querySelectorAll: selector => selector === '[data-testid]' ? [] : buttons},
        getComputedStyle: () => ({visibility:'visible', display:'block', opacity:'1'})
    };
    return vm.runInNewContext(script(name).replace('#CONTROL#', JSON.stringify(control)), context);
}
const end = button('End call');
const mic = button('Microphone', {ancestorPressed:'true'});
const camera = button('Camera', {pressed:'false'});
assert(run('webCallStateJavaScript', [end, mic, camera]).startsWith('1|muted|off|'));
assert(run('webCallStateJavaScript', [button('Start video call')]).startsWith('0|'));
assert(run('webCallStateJavaScript', [button('End call', {hidden:true}), mic]).startsWith('0|'));
assert.equal(run('webCallToggleJavaScript', [end, mic], 'mic', 'evil.test'), 'wrong host');
assert.equal(run('webCallToggleJavaScript', [button('Start video call')], 'camera'), 'no active call');
assert.equal(run('webCallToggleJavaScript', [end, mic], 'unknown'), 'unsupported');
assert.deepEqual(clicked, []);
assert(run('webCallToggleJavaScript', [button('End to end encryption'), end, mic], 'end').startsWith('clicked'));
assert.deepEqual(clicked, ['End call']);
console.log('Browser script fixture tests passed (state, hidden controls, host and action guards).');
