#include <gtest/gtest.h>
#include "V2TIMString.h"
#include "V2TIMStringHash.h"  // Test the hash function
#include <string>
#include <unordered_map>

// Test V2TIMString constructors and basic operations
TEST(V2TIMStringTest, Construction) {
    // Default constructor
    V2TIMString empty;
    EXPECT_TRUE(empty.Empty());
    EXPECT_EQ(empty.Length(), 0);
    
    // Constructor from C string
    const char* test_str = "Hello World";
    V2TIMString str1(test_str);
    EXPECT_FALSE(str1.Empty());
    EXPECT_EQ(str1.Length(), strlen(test_str));
    EXPECT_STREQ(str1.CString(), test_str);
    
    // Constructor from std::string
    std::string std_str = "Test String";
    V2TIMString str2(std_str);
    EXPECT_EQ(str2.Length(), std_str.length());
    EXPECT_STREQ(str2.CString(), std_str.c_str());
    
    // Copy constructor
    V2TIMString str3(str2);
    EXPECT_EQ(str3.Length(), str2.Length());
    EXPECT_STREQ(str3.CString(), str2.CString());
    
    // Assignment operator
    V2TIMString str4;
    str4 = str1;
    EXPECT_EQ(str4.Length(), str1.Length());
    EXPECT_STREQ(str4.CString(), str1.CString());
}

// Test string comparison operations
TEST(V2TIMStringTest, Comparison) {
    V2TIMString str1("Apple");
    V2TIMString str2("Apple");
    V2TIMString str3("Banana");

    // Equality
    EXPECT_TRUE(str1 == str2);
    EXPECT_FALSE(str1 == str3);

    // Inequality
    EXPECT_FALSE(str1 != str2);
    EXPECT_TRUE(str1 != str3);

    // Less than
    EXPECT_TRUE(str1 < str3);
    EXPECT_FALSE(str3 < str1);
    EXPECT_FALSE(str1 < str2);
    EXPECT_FALSE(str2 < str1);
    EXPECT_FALSE(str3 < str2);
}

// Test hash function for V2TIMString
TEST(V2TIMStringTest, Hash) {
    // Create an unordered_map with V2TIMString as key
    std::unordered_map<V2TIMString, int> string_map;
    
    // Add some values
    string_map[V2TIMString("one")] = 1;
    string_map[V2TIMString("two")] = 2;
    string_map[V2TIMString("three")] = 3;
    
    // Look up values
    EXPECT_EQ(string_map[V2TIMString("one")], 1);
    EXPECT_EQ(string_map[V2TIMString("two")], 2);
    EXPECT_EQ(string_map[V2TIMString("three")], 3);
    
    // Modify a value
    string_map[V2TIMString("one")] = 10;
    EXPECT_EQ(string_map[V2TIMString("one")], 10);
    
    // Check size
    EXPECT_EQ(string_map.size(), 3);
    
    // Check for non-existent key
    EXPECT_EQ(string_map.count(V2TIMString("four")), 0);
}

// Test utility methods
TEST(V2TIMStringTest, UtilityMethods) {
    V2TIMString str("  Hello World  ");
    
    // Test Empty and Length
    EXPECT_FALSE(str.Empty());
    EXPECT_EQ(str.Length(), 15);
    
    // Test CString 
    EXPECT_STREQ(str.CString(), "  Hello World  ");
    
    // Test Size (same as Length)
    EXPECT_EQ(str.Size(), str.Length());
}
