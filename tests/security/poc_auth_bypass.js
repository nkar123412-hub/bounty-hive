
const axios = require('axios');

async function testAuthBypass() {
    const TARGET_URL = 'http://localhost:3000/api/user/profile'; // Hypothetical endpoint
    const VICTIM_ADDRESS = 'EQB...some_victim_address...';

    console.log(`Testing Auth Bypass with address: ${VICTIM_ADDRESS}`);

    try {
        const response = await axios.get(TARGET_URL, {
            headers: {
                'x-ton-address': VICTIM_ADDRESS
            }
        });
        
        if (response.status === 200) {
            console.log('❌ VULNERABILITY CONFIRMED: Access granted without initData!');
            console.log('Response data:', response.data);
        } else {
            console.log(`✅ Access denied (Status: ${response.status})`);
        }
    } catch (error) {
        console.log(`✅ Access denied or Server Error: ${error.message}`);
    }
}

testAuthBypass();
