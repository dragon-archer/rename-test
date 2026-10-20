#ifdef VALUE
int FUNCTION(void) { return VALUE; }
#else
int part1(void);
int part2(void);
int part3(void);
int part4(void);
int part5(void);
int part6(void);
int part7(void);
int part8(void);

int main(void)
{
    return part1() + part2() + part3() + part4() +
           part5() + part6() + part7() + part8() != 36;
}
#endif
